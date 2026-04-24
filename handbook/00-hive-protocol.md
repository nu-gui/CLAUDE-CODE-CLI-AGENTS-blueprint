# 00 — Hive Integration Protocol (Reference)

> **Status**: Full reference. Your agent's inline preamble stub handles the first-action steps (SESSION_ID, session-folder verify, SPAWN event). Everything else lives here.
> **Schema**: Events v1 — the canonical spec is `~/.claude/context/hive/EVENTS_NDJSON_SPEC.md`. This file does **not** duplicate the schema; it documents how agents use it.
> **Protocol**: v3.8 Hive Integration (compliance is non-negotiable).
> **Headless (`claude -p`) sandbox nuances**: `docs/claude-p-sandbox.md` — mandatory flags, allowlist limits, specialist prompt contract, troubleshooting.

---

## What the inline stub already did

Before reaching this file, your preamble stub:

1. Extracted `SESSION_ID`, `PROJECT_KEY`, `SESSION_DIR`, `DEPTH` from the prompt.
2. Halted if `SESSION_ID` was missing or `DEPTH` exceeded the recursion limit.
3. Verified `~/.claude/context/hive/sessions/${SESSION_ID}/manifest.yaml` exists.
4. Emitted a `SPAWN` event to `~/.claude/context/hive/events.ndjson`.
5. Created an agent status file at `sessions/${SESSION_ID}/agents/${AGENT_ID}.status`.

**If any of those did not happen, stop and fix the stub — do not continue with the rest of this protocol.**

---

## During execution

### Checkpoints — after every non-trivial file modification

Checkpoint coverage is audited (historical baseline: 21%). Every agent writes:

```bash
mkdir -p ~/.claude/context/hive/sessions/${SESSION_ID}/agents/${AGENT_ID}
echo "{\"v\":1,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"sid\":\"${SESSION_ID}\",\"agent\":\"${AGENT_ID}\",\"checkpoint_id\":\"CP-${SEQ}\",\"todo_id\":\"${TODO_ID}\",\"status\":\"doing\",\"summary\":\"${SHORT}\",\"files_modified\":[\"${FILE}\"],\"next_actions\":[\"…\"],\"blockers\":[]}" \
  >> ~/.claude/context/hive/sessions/${SESSION_ID}/agents/${AGENT_ID}/checkpoints.ndjson
```

Status values: `todo` | `doing` | `done` | `blocked`. Append-only. Summary ≤ 3 lines. Full schema in `EVENTS_NDJSON_SPEC.md` § "Agent Checkpoint Logs".

**Checkpoint trivial edits too** if they land in a file any downstream agent reads. Skipping breaks crash recovery.

### PROGRESS events — at significant milestones

```bash
echo "{\"v\":1,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"sid\":\"${SESSION_ID}\",\"project_key\":\"${PROJECT_KEY}\",\"agent\":\"${AGENT_ID}\",\"event\":\"PROGRESS\",\"task\":\"${TASK}\",\"detail\":\"${MILESTONE}\"}" \
  >> ~/.claude/context/hive/events.ndjson
```

Use for user-visible milestones (design ratified, feature behind flag, tests passing). Not for every file write — that's what checkpoints are for.

### BATCH events — for high-frequency emitters

If you generate > 10 events per second (e.g. `test-00` streaming 1,000 test results), use a BATCH event instead of individual PROGRESS events. Schema + rules in `EVENTS_NDJSON_SPEC.md` § "BATCH Event Format". Never batch SPAWN / SESSION_START / SESSION_END / COMPLETE / FAILED.

### CONTEXT_LOADED event — recommended

If you read context files before work (landing.yaml, RESUME_PACKET.md, this handbook), emit one CONTEXT_LOADED event listing what you read. SUP-00 uses it to check V-001 compliance.

```bash
echo "{\"v\":1,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"sid\":\"${SESSION_ID}\",\"project_key\":\"${PROJECT_KEY}\",\"agent\":\"${AGENT_ID}\",\"event\":\"CONTEXT_LOADED\",\"files_read\":[\"CLAUDE.md\",\"handbook/00-hive-protocol.md\",\"handbook/07-decision-guide.md\"]}" \
  >> ~/.claude/context/hive/events.ndjson
```

---

## Before return — always

1. **Emit COMPLETE** (or FAILED / BLOCKED):

   ```bash
   echo "{\"v\":1,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"sid\":\"${SESSION_ID}\",\"project_key\":\"${PROJECT_KEY}\",\"agent\":\"${AGENT_ID}\",\"event\":\"COMPLETE\",\"task\":\"${TASK}\",\"outputs\":[\"${FILE1}\",\"${FILE2}\"],\"exit_code\":0}" \
     >> ~/.claude/context/hive/events.ndjson
   ```

   Event compliance baseline was 38%. Every agent MUST emit a terminal event. Silent returns break the audit trail and SUP-00's recovery-readiness check.

2. **Update agent status file** to `status: complete` (or `blocked` / `error`) with a UTC `completed` timestamp and the outputs list.

3. **Update `RESUME_PACKET.md`** in the session folder:
   - Append your outputs to the "Recently Modified Files" table.
   - Update your row in the "Last Checkpoint Per Agent" table.
   - Add a one-line entry under "Completed Work" (or move an existing TODO to done).
   - Note any follow-up items as new rows in the TODO table.

4. **If you wrote checkpoints, ensure the final one matches your COMPLETE event** — same files, same task.

---

## Failure mode

If you cannot finish:

1. Emit `BLOCKED` or `FAILED` with `reason` (and `depends_on` for BLOCKED).
2. Update status file to `blocked` or `error`.
3. Write a closing checkpoint describing what stopped you and what the next agent needs.
4. Return a clear human-readable explanation. Do not silently return partial work.

| Situation | Event | Status | Checkpoint status |
|---|---|---|---|
| Dependency not yet available | `BLOCKED` + `depends_on` | `blocked` | `blocked` |
| Unrecoverable error | `FAILED` + `error` | `error` | `blocked` |
| User-requested abort | `FAILED` + `reason:"user-cancel"` | `error` | `blocked` |
| Context exhaustion | `BLOCKED` + `reason:"context-limit"` | `blocked` | `blocked` |

---

## Depth and recursion

- Your prompt carries `depth N/M` when spawned by another agent.
- If `N ≥ M`, HALT with a recursion error. Never silently spawn at max depth.
- Default `M` is 2. Orchestrators may set higher (up to 4) for complex fan-outs; see `04-capabilities-matrix.md`.
- Headless children spawned via `claude -p` count toward depth. Pass a decremented depth in the child's prompt (see `06-recipes.md`).

---

## Single-writer discipline

| Resource | Single writer |
|---|---|
| `todo.yaml` | CTX-00 or ORC-00 only. Other agents write delta files under `todo_deltas/`. |
| `RESUME_PACKET.md` | CTX-00 primarily, ORC-00 as fallback. Specialists may append to clearly scoped sections. |
| `manifest.yaml` | CTX-00 only. |
| `events.ndjson` | All agents (append-only, atomic line writes). |
| `agents/<id>/checkpoints.ndjson` | Owning agent only. |

Violating single-writer contracts corrupts session state faster than anything else in this protocol.

---

## Validation + violations

SUP-00 enforces these on session close. Fix at the source, not by editing history.

| ID | Violation | Severity | Where caught |
|---|---|---|---|
| V-001 | Work without `CONTEXT_LOADED` | MEDIUM | SUP-00 session audit |
| V-006 | File modified without checkpoint | HIGH | SUP-00 / HALT agent |
| V-007 | TODO registry not updated after checkpoint | MEDIUM | auto-repair, WARN |
| V-008 | Parallel dispatch without recovery readiness | HIGH | ORC-00 dispatch-gate |
| V-009 | Agent spawned without SESSION_ID | CRITICAL | preamble stub halts |
| V-010 | Session folder missing | HIGH | preamble stub halts |
| V-011 | SPAWN event not emitted | HIGH | SUP-00 audit |

See `EVENTS_NDJSON_SPEC.md` § "Governance Enforcement Updates" for the full violation table and DEV-MODE relaxation.

---

## Recovery — when resuming a crashed session

1. Read `~/.claude/context/hive/sessions/<SESSION_ID>/RESUME_PACKET.md`.
2. Read `sessions/<SESSION_ID>/todo.yaml`.
3. For each agent listed, read the last 10 entries of `agents/<agent>/checkpoints.ndjson`.
4. Resume from the first `doing` or `todo` item.
5. Before writing your first new checkpoint, emit a PROGRESS event with `detail:"resumed-from-<CP-ID>"` so the timeline reflects continuity.

Never delete or rewrite old checkpoints. Append a new one saying "superseded by CP-XXX" if a recovery decision invalidates prior state.

---

## Hook integration

`~/.claude/hooks/hive-subagent-start.sh` emits a SPAWN event automatically when a sub-agent is started via the Task tool. **That does not cover `claude -p` headless children** — those you spawn yourself must emit SPAWN manually using the recipe in `06-recipes.md`. The hook will not fire for them.

Generic agent types (`Explore`, `Plan`, `general-purpose`, `claude-code-guide`, `statusline-setup`) are excluded by the hook and do not appear in `events.ndjson`. Do not rely on their lifecycle being tracked.

---

## Compliance quick-reference

| When | Required | Emit/write |
|---|---|---|
| On spawn | YES | `SPAWN` event + status file (handled by stub) |
| Before first file read | RECOMMENDED | `CONTEXT_LOADED` event |
| After file modification | YES | Checkpoint line |
| At milestone | YES (if externally visible) | `PROGRESS` event |
| Entering blocked state | YES | `BLOCKED` event + status flip + checkpoint |
| On every 10+ events/sec burst | YES | `BATCH` event instead of individuals |
| Before return | YES | `COMPLETE`/`FAILED`/`BLOCKED` event + status flip + `RESUME_PACKET.md` update |

If you are uncertain which event applies, prefer emitting over not emitting. SUP-00's audit treats missing events as harder failures than surplus ones.
