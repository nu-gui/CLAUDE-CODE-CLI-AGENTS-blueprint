# Session Intelligence Protocol v1.0

**Status**: Active
**Effective Date**: 2025-12-27
**Version**: 1.0
**Owner**: CTX-00 (Context Manager)
**Mode**: Ultra-Strict (Autonomous-Safe)

---

## Purpose

Make session context queryable and comparable in O(1). Enable ORC-00 to answer "what changed since last session?" without opening run artifacts.

---

## 1. Session Index (Project-Scoped)

### File Location

```
~/.claude/context/projects/{PROJECT_KEY}/session_index.yaml
```

### Schema

```yaml
# Session Index - Compiled by CTX-00
# Append-only. One entry per session.

project_key: ai-agents-org
last_updated: 2025-12-27T16:00:00Z

sessions:
  - session_id: ai-agents-org_2025-12-27_1430
    created: 2025-12-27T14:30:00Z
    run_ids: [ai-agents-org_2025-12-27_1430_orc-00_1, ai-agents-org_2025-12-27_1430_api-core_1]
    task_ids: [TASK-017, TASK-018]
    confidence: GREEN
    domains: [api-core, test-00]
    outcomes:
      completed: 2
      blocked: 0
      created: 1
    open_hoffs_count: 0
    open_escs_count: 0
    digest_path: ./sessions/ai-agents-org_2025-12-27_1430.digest.yaml
```

### Field Constraints

| Field | Type | Max Size | Validation |
|-------|------|----------|------------|
| `session_id` | string | 64 chars | Must match SESSION_ID format |
| `run_ids` | array | 20 items | Each must match RUN_ID format |
| `task_ids` | array | 50 items | Each must exist in events |
| `domains` | array | 17 items | Must be valid agent IDs |
| `confidence` | enum | - | GREEN, YELLOW, RED |
| `digest_path` | path | - | Must exist |

### Update Triggers

| Event | Action |
|-------|--------|
| Session end | Append new entry |
| Digest created | Update `digest_path` |
| Confidence change | Update entry (only `confidence` field mutable) |

### Single Writer

CTX-00 only. Other agents read-only.

---

## 2. Digest Delta (Session-to-Session Diff)

### File Location

```
~/.claude/context/projects/{PROJECT_KEY}/sessions/{SESSION_ID}.delta.yaml
```

### Schema

```yaml
# Digest Delta - Compiled by CTX-00
# IDs only. No prose. Bounded size.

session_id: ai-agents-org_2025-12-27_1430
previous_session_id: ai-agents-org_2025-12-26_0930
created: 2025-12-27T16:30:00Z

added:
  tasks: [TASK-019]
  decisions: [DEC-009]
  patterns: [PATTERN-011]
  lessons: []
  files_touched: [src/api/endpoints.ts, src/api/handlers.ts]

removed:
  tasks: []           # Tasks completed/cancelled
  blockers: [TASK-015]  # Blockers resolved

state_changes:
  tasks_completed: [TASK-017, TASK-018]
  tasks_blocked: []
  hoffs_resolved: [HOFF-042]
  escs_resolved: []
```

### Field Constraints

| Field | Type | Max Items | Notes |
|-------|------|-----------|-------|
| `added.tasks` | array | 20 | New task IDs |
| `added.decisions` | array | 5 | New DEC-XXX |
| `added.patterns` | array | 5 | New PATTERN-XXX |
| `added.lessons` | array | 5 | New LESSON-XXX |
| `added.files_touched` | array | 50 | Paths only |
| `removed.*` | array | 20 | IDs only |
| `state_changes.*` | array | 20 | IDs only |

### Generation Rules

| Rule | Enforcement |
|------|-------------|
| Single writer | CTX-00 only |
| Previous session required | If no previous session, delta is empty |
| IDs only | No descriptions, no prose |
| Immutable | Once created, never modified |
| Bounded | Total lines ≤ 40 |

---

## 3. Recovery Path

If `session_index.yaml` is corrupted or missing:

1. CTX-00 scans `sessions/*.digest.yaml`
2. Rebuilds index from digest metadata
3. Computes deltas from consecutive digests
4. Logs recovery event to `events.ndjson`

**Recovery is deterministic**: Same digests → same index.

---

## 4. Fail-Closed Conditions

| Condition | Action |
|-----------|--------|
| `session_index.yaml` missing | CTX-00 must create before ORC-00 dispatch |
| Delta references non-existent ID | REJECT delta, log error, CTX-00 must repair |
| Index entry missing `digest_path` | Mark session as INCOMPLETE, exclude from routing |
| Confidence mismatch (index vs landing) | Landing.yaml takes precedence, update index |

---

## 5. ORC-00 Usage

ORC-00 queries session intelligence for:

1. **What changed?** → Read latest delta
2. **Which domains active?** → Read index `domains` field
3. **Session health?** → Read index `confidence` field
4. **Prior work exists?** → Check index `sessions` count

**ORC-00 MUST NOT open digests/summaries if index + delta answer the query.**

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-12-27 | Initial protocol |
