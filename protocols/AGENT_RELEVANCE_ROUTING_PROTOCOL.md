# Agent Relevance Routing Protocol v1.0

**Status**: Active
**Effective Date**: 2025-12-27
**Version**: 1.0
**Owner**: ORC-00 (Orchestrator)
**Mode**: Ultra-Strict (Autonomous-Safe)

---

## Purpose

Dispatch the most context-primed agent, not the closest match by label. Reduce rehydration chatter and cross-domain misroutes.

---

## 1. Relevance Score Inputs

ORC-00 computes a relevance score per agent for each TASK using these inputs:

### Input Factors

| Factor | Weight | Source | Description |
|--------|--------|--------|-------------|
| Ownership History | 30% | Accepted HOFFs | Agent has prior accepted handoffs for this domain |
| Domain Recency | 25% | session_index.yaml | Agent touched this domain in last N sessions |
| Decision Proximity | 20% | DEC-XXX references | Task references decisions agent participated in |
| Blocker Awareness | 15% | Open ESCs/HOFFs | Agent has unresolved blockers in this domain |
| Capability Match | 10% | Agent roster | Agent's defined domain matches task type |

### Score Computation (Conceptual)

```
relevance_score =
    0.30 * ownership_score +
    0.25 * recency_score +
    0.20 * decision_proximity_score +
    0.15 * blocker_awareness_score +
    0.10 * capability_score
```

**Implementation Note**: Actual algorithm is implementation-defined. This protocol defines the decision contract, not the implementation.

---

## 2. ORC-00 Routing Rules

### Dispatch Decision Contract

1. **Compute relevance scores** for all candidate agents
2. **Filter by confidence gate**: Exclude agents if project confidence is RED
3. **Select highest scorer** that passes gate
4. **Log dispatch decision** to dispatch_snapshot.yaml

### Routing Priority

| Priority | Condition | Action |
|----------|-----------|--------|
| 1 | Confidence RED | HALT. No dispatch. |
| 2 | Single clear winner (score > 2nd by 20%+) | Dispatch to winner |
| 3 | Close scores (within 10%) | Prefer agent with fewer active tasks |
| 4 | Tie | Prefer agent with most recent domain activity |
| 5 | No qualified agent | Escalate to ORC-00 for manual routing |

### Confidence Gate Interaction

| Confidence | Routing Behavior |
|------------|------------------|
| GREEN | Normal routing by relevance score |
| YELLOW | Routing allowed with logged warning |
| RED | Routing blocked. CTX-00 must repair first. |

---

## 3. Relevance Data Sources

### From session_index.yaml

```yaml
sessions:
  - session_id: ...
    domains: [api-core, data-core]  # → Domain recency
    task_ids: [TASK-017]            # → Ownership inference
```

### From handoffs/

```yaml
# HOFF-042
from_agent: api-core
to_agent: test-00
status: ACCEPTED  # → Ownership history
```

### From shared/decisions/

```yaml
# DEC-009
participants: [api-core, api-gov]  # → Decision proximity
related_tasks: [TASK-017]
```

### From escalations/

```yaml
# ESC-003
blocking_agents: [data-core]  # → Blocker awareness
status: OPEN
```

---

## 4. Anti-Patterns (Prohibited)

| Pattern | Why Prohibited |
|---------|----------------|
| Route by label only | Ignores context, causes rehydration |
| Route to least-busy | Ignores expertise, causes misroutes |
| Route without score logging | Unauditable |
| Route when confidence RED | Violates fail-closed |

---

## 5. Fail-Closed Conditions

| Condition | Action |
|-----------|--------|
| session_index.yaml missing | Cannot compute recency. HALT until CTX-00 creates. |
| No agent scores > 0 | Escalate. Do not dispatch. |
| Confidence RED | Block all dispatch. CTX-00 must repair. |
| Relevance data stale (>24h) | WARN. Proceed with degraded scoring. |

---

## 6. Audit Requirements

Every dispatch decision MUST be recorded in `dispatch_snapshot.yaml` with:

- Selected agent
- Relevance score
- Runner-up agent and score
- Confidence threshold at decision time
- Override flag if human override used

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-12-27 | Initial protocol |
