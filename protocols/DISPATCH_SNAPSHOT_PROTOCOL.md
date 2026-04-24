# Dispatch Snapshot Protocol v1.0

**Status**: Active
**Effective Date**: 2025-12-27
**Version**: 1.0
**Owner**: ORC-00 (Orchestrator)
**Mode**: Ultra-Strict (Autonomous-Safe)

---

## Purpose

Make ORC-00 dispatch decisions auditable and reproducible. Enable tracing any dispatch back to deterministic state.

---

## 1. File Location

```
~/.claude/context/projects/{PROJECT_KEY}/runs/{RUN_ID}/dispatch_snapshot.yaml
```

---

## 2. Schema

```yaml
# Dispatch Snapshot - Written by ORC-00
# One per dispatch decision. Immutable after creation.

dispatch_id: ai-agents-org_2025-12-27_1430_orc-00_1_dispatch
created: 2025-12-27T14:30:05Z

# Context at decision time
project_key: ai-agents-org
session_id: ai-agents-org_2025-12-27_1430
confidence: GREEN

# Task selection
task_ids_selected:
  - TASK-019

# Agent dispatch
agents_dispatched:
  - agent_id: api-core
    task_id: TASK-019
    relevance_score: 0.82
    runner_up:
      agent_id: api-gov
      relevance_score: 0.65

# Routing basis (IDs only)
routing_basis:
  landing_yaml: ./landing.yaml
  digest: ./sessions/ai-agents-org_2025-12-27_1430.digest.yaml
  session_index: ./session_index.yaml
  open_hoffs: []
  open_escs: []

# Override tracking
override_used: false
override_reason: null
override_by: null
```

---

## 3. Field Constraints

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `dispatch_id` | string | Yes | Unique per dispatch |
| `project_key` | string | Yes | Must match PROJECT_KEY format |
| `session_id` | string | Yes | Must match SESSION_ID format |
| `confidence` | enum | Yes | GREEN, YELLOW, RED |
| `task_ids_selected` | array | Yes | At least one |
| `agents_dispatched` | array | Yes | At least one |
| `relevance_score` | float | Yes | 0.0 - 1.0 |
| `routing_basis.*` | paths | Yes | All must exist |
| `override_used` | bool | Yes | Default false |
| `override_reason` | string | Conditional | Required if override_used=true |

---

## 4. Retention Rules

| Rule | Specification |
|------|---------------|
| Minimum retention | 30 days |
| Archive location | `~/.claude/context/archive/dispatches/` |
| Deletion | Only after archive |
| Immutability | Never modified after creation |

---

## 5. Creation Triggers

| Event | Action |
|-------|--------|
| ORC-00 selects task for dispatch | Create dispatch_snapshot.yaml |
| Multiple tasks dispatched | One snapshot per dispatch decision |
| Re-dispatch after failure | New snapshot with reference to prior |

---

## 6. Audit Use Cases

### Trace a Misroute

1. Find dispatch_snapshot for failed task
2. Check `relevance_score` vs `runner_up`
3. Verify `routing_basis` files existed at time
4. Check if `override_used`

### Reproduce Decision

1. Load `routing_basis` files as they were
2. Re-compute relevance scores
3. Verify same agent selected

### Detect Override Abuse

1. Query snapshots where `override_used=true`
2. Validate `override_reason` is substantive
3. Flag repeated overrides for same domain

---

## 7. Fail-Closed Conditions

| Condition | Action |
|-----------|--------|
| Cannot write snapshot | HALT dispatch. Log error. |
| Routing basis file missing | HALT. CTX-00 must repair. |
| Invalid confidence at dispatch | REJECT. Log violation. |
| Snapshot already exists for dispatch_id | ERROR. Duplicate dispatch detected. |

---

## 8. Integration

### With ORC-00

- ORC-00 creates snapshot before agent activation
- Snapshot creation is atomic with dispatch

### With SUP-00

- SUP-00 may query snapshots for audit
- Read-only access

### With CTX-00

- CTX-00 archives old snapshots
- CTX-00 may rebuild index from snapshots

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-12-27 | Initial protocol |
