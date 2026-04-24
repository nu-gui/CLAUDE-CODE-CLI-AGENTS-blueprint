# Agent Handoff Protocol v3.4

**Status**: Active
**Effective Date**: 2025-12-27
**Version**: 3.4 (Session/Memory Handoff Improvements)
**Owner**: CTX-00 (Context Manager)
**Applies To**: All 17 agents in the AI Agent Organization Suite

---

## Table of Contents

1. [Protocol Purpose](#protocol-purpose)
2. [Handoff Definition](#handoff-definition)
3. [Handoff Types](#handoff-types)
4. [Pre-Handoff Checklist](#pre-handoff-checklist)
5. [Work Package Format](#work-package-format)
6. [Acceptance Criteria Template](#acceptance-criteria-template)
7. [Handoff Execution Process](#handoff-execution-process)
8. [Coordination Checkpoints](#coordination-checkpoints)
9. [Escalation Procedures](#escalation-procedures)
10. [Rollback Coordination](#rollback-coordination)
11. [Agent-Specific Considerations](#agent-specific-considerations)
12. [Protocol Compliance](#protocol-compliance)

---

## Protocol Purpose

This protocol establishes standardized procedures for transferring work, knowledge, and accountability between agents in the multi-agent system. It ensures:

- **Continuity**: No information loss during transitions
- **Clarity**: Clear ownership and expectations
- **Quality**: Consistent deliverable standards
- **Efficiency**: Minimal rework and context-switching overhead
- **Traceability**: Full audit trail of work flow

---

## Tightened HOFF Schema (v3.4)

All handoffs MUST use this validated YAML schema. Fail-closed enforcement applies.

### File Location

```
~/.claude/context/handoffs/HOFF-{seq}_{from}_{to}.yaml
```

### Required Schema

```yaml
# Metadata (all required)
handoff_id: HOFF-042              # Sequential ID
created: 2025-12-27T14:35:00Z     # ISO8601 timestamp
project_key: ai-agents-org        # Must exist in index.yaml
session_id: ai-agents-org_2025-12-27_1430  # Format: {PROJECT_KEY}_{YYYY-MM-DD}_{HHmm}

# Routing (all required)
from_agent: api-core              # Must be valid agent ID
to_agent: test-00-test-runner     # Must be valid agent ID
reason: "Implementation complete, ready for test execution"

# Task References (required, validates against active_tasks.json)
task_refs:
  - TASK-017                      # Must exist in active_tasks.json

# Context Bundle (required)
context_bundle:
  files_changed:                  # List of modified files
    - src/api/endpoints.ts
    - src/api/handlers.ts
  decisions_made:                 # Must exist in shared/decisions/
    - DEC-023
  blockers: []                    # Empty array if none

# Acceptance Criteria (required, at least one)
acceptance_criteria:
  - "All unit tests pass"
  - "Coverage >= 80%"

# Status Tracking (required)
status: PENDING                   # PENDING | ACCEPTED | REJECTED
accepted_by: null                 # Agent ID when accepted
accepted_at: null                 # ISO8601 when accepted
rejection_reason: null            # Required if status=REJECTED
```

### Validation Rules (Fail-Closed)

| Field | Validation | On Failure |
|-------|------------|------------|
| `project_key` | Must exist in `index.yaml` projects | REJECT handoff |
| `session_id` | Must match format `{PROJECT_KEY}_{YYYY-MM-DD}_{HHmm}` | REJECT handoff |
| `from_agent` / `to_agent` | Must be valid agent IDs from roster | REJECT handoff |
| `task_refs` | All must exist in `active_tasks.json` | REJECT handoff |
| `decisions_made` | All must exist in `shared/decisions/` | REJECT handoff |
| `status` | Only valid transitions: PENDING→ACCEPTED, PENDING→REJECTED | ERROR |
| `acceptance_criteria` | Must have at least one item | REJECT handoff |

### Status Transitions

```
PENDING ──┬──→ ACCEPTED (by to_agent)
          │
          └──→ REJECTED (by to_agent, with rejection_reason)
```

**Rules:**
- Only `to_agent` can change status from PENDING
- ACCEPTED/REJECTED are terminal states
- `rejection_reason` is REQUIRED when status=REJECTED

---

## Handoff Definition

### What Constitutes a Handoff

A **handoff** occurs when:

1. Primary responsibility for a deliverable transfers from one agent to another
2. Work enters a different domain (e.g., backend → database → frontend)
3. A dependency is satisfied and unblocks the next agent
4. A work package requires specialized expertise outside current agent's domain

### What is NOT a Handoff

- **Collaboration**: Multiple agents working simultaneously on different aspects
- **Consultation**: One agent seeking advice without transferring ownership
- **Review**: Quality check without ownership transfer
- **Parallel Work**: Independent tasks with no direct dependency

### When Handoffs are Required

Mandatory handoff scenarios:

| Scenario | From Agent | To Agent | Trigger |
|----------|-----------|----------|---------|
| API schema → implementation | API-GOV | Backend agent (API-CORE, API-GW, etc.) | Schema approved |
| Database schema → migration | DATA-CORE | Backend agent | Schema finalized |
| Backend implementation → frontend integration | Backend agent | FRONT-UI | API stable, documented |
| Feature complete → testing | Any dev agent | QA-GUARD | Implementation done |
| Critical bug identified → security review | Any agent | SEC-SHIELD | Security flag raised |
| Infrastructure change → deployment | DevOps agents | OPS-INFRA | Config ready |
| Blocked task → orchestration | Any agent | ORC-00 | Blocker identified |
| Quality failure → remediation | SUP-00 | Responsible agent | Quality gate failed |

---

## Handoff Types

### 1. Sequential Handoff
**Definition**: Linear transfer where Agent A completes work, then Agent B begins.

**Example**: API-GOV defines schema → API-CORE implements endpoints

**Requirements**:
- 100% completion by sender
- Acceptance criteria met
- All tests passing

### 2. Staged Handoff
**Definition**: Partial transfer where phases are handed off incrementally.

**Example**: DATA-CORE provides read endpoints → FRONT-UI builds views → DATA-CORE adds write endpoints

**Requirements**:
- Clear phase boundaries
- Phase completion criteria
- Coordination checkpoints between phases

### 3. Parallel Handoff
**Definition**: Work split into independent streams handed to multiple agents.

**Example**: ORC-00 decomposes feature → hands API work to API-CORE + DB work to DATA-CORE simultaneously

**Requirements**:
- Clear interface contracts
- Dependency map
- Integration plan

### 4. Emergency Handoff
**Definition**: Immediate transfer due to blocker, escalation, or agent unavailability.

**Example**: Security vulnerability found → SEC-SHIELD takes over immediately

**Requirements**:
- Current state snapshot
- Known issues documented
- Escalation justification

---

## Pre-Handoff Checklist

Before initiating ANY handoff, the **sending agent** must complete:

### Phase 1: Work Package Validation

```markdown
## Work Package Validation Checklist

### Deliverables
- [ ] All committed artifacts created/updated
- [ ] Code committed to version control (if applicable)
- [ ] Documentation complete and accurate
- [ ] Configuration files updated
- [ ] Dependencies explicitly listed

### Quality Gates
- [ ] All tests passing (unit, integration, as applicable)
- [ ] Linting/formatting standards met
- [ ] Security scan completed (if code changes)
- [ ] Performance benchmarks met (if applicable)
- [ ] Code review completed (if required)

### Documentation
- [ ] README updated (if public interface changed)
- [ ] API documentation generated (if endpoints added)
- [ ] Architecture diagrams updated (if structure changed)
- [ ] CHANGELOG.md updated with changes
- [ ] Known issues/limitations documented

### Context Preservation
- [ ] Decision rationale captured in context store
- [ ] Alternatives considered documented
- [ ] Edge cases and gotchas noted
- [ ] Environment-specific considerations listed
- [ ] Rollback procedure defined (if applicable)

### Dependency Management
- [ ] All blocking dependencies satisfied
- [ ] Non-blocking dependencies documented
- [ ] External dependencies validated (versions, availability)
- [ ] Database migrations applied (if schema changed)
- [ ] Feature flags configured (if applicable)

### Communication
- [ ] Work package document created
- [ ] Acceptance criteria defined
- [ ] Receiving agent notified
- [ ] Timeline expectations communicated
- [ ] Handoff meeting scheduled (if complex)
```

### Phase 2: Receiving Agent Validation

The **receiving agent** must verify:

```markdown
## Receiving Agent Acceptance Checklist

### Understanding
- [ ] Work package scope clear
- [ ] Acceptance criteria understood
- [ ] Dependencies verified available
- [ ] Timeline feasible
- [ ] Resources available (access, tools, environments)

### Validation
- [ ] Artifacts accessible and complete
- [ ] Tests can be run successfully
- [ ] Documentation matches actual state
- [ ] Known issues acknowledged
- [ ] Rollback procedure understood

### Readiness
- [ ] No blockers to starting work
- [ ] Required expertise available
- [ ] Priority confirmed with ORC-00 (if needed)
- [ ] Acceptance criteria achievable
```

**If any checklist item fails**: Handoff is rejected, returns to sender with specific gaps identified.

---

## Work Package Format

All handoffs must include a YAML-formatted work package stored in:

```
~/.claude/context/handoffs/YYYY-MM-DD-{from-agent}-to-{to-agent}-{issue-id}.yaml
```

### Standard Work Package Template

```yaml
handoff:
  # Metadata
  id: "handoff-2025-11-27-api-gov-to-api-core-232"
  created_at: "2025-11-27T14:30:00Z"
  from_agent: "API-GOV"
  to_agent: "API-CORE"
  type: "sequential"  # sequential | staged | parallel | emergency
  priority: "high"    # critical | high | medium | low
  estimated_duration: "2 days"

  # Context
  issue_reference: "#232"
  sprint: "Sprint 1.8"
  epic: "JWT Authentication System"

  # Deliverables
  artifacts:
    - path: "${HOME}/github/${GITHUB_ORG:-your-org}/example-repo-AI/docs/JWT_AUTH_IMPLEMENTATION_PLAN.md"
      type: "documentation"
      status: "complete"
      sha256: "abc123..."  # File hash for verification

    - path: "${HOME}/github/${GITHUB_ORG:-your-org}/example-repo-AI/docs/api-schemas/auth-endpoints.yaml"
      type: "schema"
      status: "complete"
      sha256: "def456..."

    - path: "${HOME}/github/${GITHUB_ORG:-your-org}/example-repo-AI/database_schema/006_auth_tokens.sql"
      type: "database_schema"
      status: "complete"
      sha256: "ghi789..."
      notes: "Applied to dev environment, ready for prod"

  # Dependencies
  dependencies_met:
    - id: "#236"
      description: "Database schema migrations complete"
      verified_at: "2025-11-26T18:00:00Z"
      verified_by: "DATA-CORE"

    - id: "#240"
      description: "Redis cluster configured"
      verified_at: "2025-11-27T10:00:00Z"
      verified_by: "OPS-INFRA"

  dependencies_pending:
    - id: "#244"
      description: "Load balancer SSL certificates"
      required_by: "2025-11-28"
      blocking: false
      owner: "OPS-INFRA"

  # Work Definition
  scope:
    description: |
      Implement JWT authentication endpoints as per specification:
      - POST /auth/login (username/password → access + refresh tokens)
      - POST /auth/refresh (refresh token → new access token)
      - POST /auth/logout (invalidate refresh token)
      - GET /auth/verify (validate access token)

    in_scope:
      - "Token generation with RS256 algorithm"
      - "Token validation middleware"
      - "Refresh token rotation"
      - "Token blacklist on logout"
      - "Multi-tenant token claims"

    out_of_scope:
      - "Password reset flow (separate story #250)"
      - "2FA/MFA (Phase 2)"
      - "OAuth2 social login (future)"

  # Acceptance Criteria
  acceptance_criteria:
    functional:
      - criterion: "Login endpoint returns valid JWT tokens"
        test: "test/api/auth/test_login.py::test_successful_login"

      - criterion: "Invalid credentials return 401"
        test: "test/api/auth/test_login.py::test_invalid_credentials"

      - criterion: "Refresh endpoint extends session"
        test: "test/api/auth/test_refresh.py::test_token_refresh"

      - criterion: "Logout invalidates refresh token"
        test: "test/api/auth/test_logout.py::test_logout_invalidates_token"

      - criterion: "Expired tokens rejected"
        test: "test/api/auth/test_validation.py::test_expired_token"

    non_functional:
      - criterion: "Login responds within 200ms (p95)"
        measurement: "Prometheus metric: http_request_duration_seconds{endpoint='/auth/login', quantile='0.95'} < 0.2"

      - criterion: "Token validation < 10ms"
        measurement: "Benchmark: pytest-benchmark test_token_validation"

      - criterion: "No secrets logged"
        measurement: "Security scan: pytest -m security test/api/auth/"

      - criterion: "OWASP Top 10 compliance"
        measurement: "ZAP scan: docker run owasp/zap2docker-stable baseline"

    coverage:
      - "Unit test coverage >= 90%"
      - "Integration test coverage >= 80%"
      - "All edge cases from JWT_AUTH_IMPLEMENTATION_PLAN.md tested"

    documentation:
      - "OpenAPI spec updated with /auth/* endpoints"
      - "README.md includes authentication flow diagram"
      - "Environment variables documented in .env.example"

  # Known Issues
  known_issues:
    - severity: "medium"
      description: "Redis HA not yet configured in production"
      impact: "Token blacklist not replicated across instances"
      workaround: "Single Redis instance acceptable for MVP"
      tracking: "#260"

    - severity: "low"
      description: "Token expiry times hardcoded"
      impact: "Cannot adjust per-tenant without code change"
      workaround: "Default 1h access / 7d refresh sufficient for now"
      tracking: "#262"

  # Technical Context
  technical_notes:
    architecture_decisions:
      - "Using RS256 (asymmetric) instead of HS256 to enable distributed validation"
      - "Refresh tokens stored in Redis with 7-day TTL"
      - "Access tokens stateless (not stored server-side)"

    environment_config:
      - var: "JWT_PRIVATE_KEY"
        location: "Vault secret: /secret/example-repo/jwt/private-key"
        format: "PEM-encoded RSA 2048-bit"

      - var: "JWT_PUBLIC_KEY"
        location: "Vault secret: /secret/example-repo/jwt/public-key"
        format: "PEM-encoded RSA 2048-bit"

      - var: "JWT_ACCESS_EXPIRY"
        value: "3600"
        unit: "seconds"

      - var: "JWT_REFRESH_EXPIRY"
        value: "604800"
        unit: "seconds"

    edge_cases:
      - "Clock skew between servers: Allow 30s leeway in nbf/exp validation"
      - "Token issued during tenant suspension: Include tenant_status in claims"
      - "Concurrent logout requests: Redis SETNX for idempotency"

  # Next Actions
  next_actions:
    immediate:
      - action: "Review JWT_AUTH_IMPLEMENTATION_PLAN.md"
        owner: "API-CORE"
        deadline: "2025-11-27T16:00:00Z"

      - action: "Set up test environment with Redis"
        owner: "API-CORE"
        deadline: "2025-11-27T17:00:00Z"

      - action: "Implement token generation logic"
        owner: "API-CORE"
        deadline: "2025-11-28T12:00:00Z"

    follow_up:
      - action: "Integration with existing /users endpoints"
        owner: "API-CORE"
        notes: "Coordinate with DATA-CORE on user lookup optimization"

      - action: "Performance testing under load"
        owner: "QA-GUARD"
        trigger: "After API-CORE marks endpoints complete"

  # Rollback Plan
  rollback:
    trigger_conditions:
      - "Authentication failures > 5% of requests"
      - "Token validation latency > 50ms"
      - "Security vulnerability discovered"

    procedure:
      - step: 1
        action: "Revert API code to previous release"
        command: "git revert {commit_sha}"

      - step: 2
        action: "Roll back database migration 006"
        command: "alembic downgrade -1"

      - step: 3
        action: "Flush Redis token blacklist"
        command: "redis-cli FLUSHDB"

      - step: 4
        action: "Notify dependent services"
        recipients: ["FRONT-UI", "API-GW", "ORC-00"]

    state_restoration:
      - "Previous session-based auth automatically re-enabled via feature flag"
      - "Existing user sessions remain valid (no logout required)"
      - "New logins fall back to session cookies"

  # Communication
  stakeholders:
    - agent: "API-GW"
      role: "Consumer"
      notification: "New /auth/* endpoints available for gateway routing"

    - agent: "FRONT-UI"
      role: "Consumer"
      notification: "Token storage pattern documented in README.md"

    - agent: "SEC-SHIELD"
      role: "Reviewer"
      notification: "Security review required before production deployment"

    - agent: "OPS-INFRA"
      role: "Dependency"
      notification: "Redis HA required for production (issue #260)"

  coordination_checkpoint:
    scheduled_at: "2025-11-28T10:00:00Z"
    attendees: ["API-CORE", "API-GOV", "ORC-00"]
    agenda:
      - "Review implementation progress"
      - "Validate acceptance criteria met"
      - "Address any blockers"
      - "Plan integration testing"

  # Verification
  verification:
    handoff_accepted_by: "API-CORE"
    accepted_at: "2025-11-27T14:45:00Z"
    checklist_completed: true
    questions_resolved: true
    estimated_completion: "2025-11-29T17:00:00Z"
```

### Simplified Work Package (for small tasks)

For low-complexity handoffs (< 4 hours of work), use abbreviated format:

```yaml
handoff:
  id: "handoff-2025-11-27-data-core-to-api-core-244"
  from_agent: "DATA-CORE"
  to_agent: "API-CORE"
  issue_reference: "#244"

  summary: "Add pagination to /customers endpoint"

  artifacts:
    - "/docs/api-schemas/customers.yaml (updated with limit/offset params)"

  acceptance_criteria:
    - "GET /customers?limit=50&offset=100 returns correct page"
    - "Response includes pagination metadata (total_count, has_next)"
    - "OpenAPI spec updated"

  next_actions:
    - "Implement query parameter parsing"
    - "Update controller logic"
    - "Add pagination tests"

  handoff_accepted_by: "API-CORE"
  accepted_at: "2025-11-27T15:00:00Z"
```

---

## Acceptance Criteria Template

Every work package must include testable, measurable acceptance criteria.

### Functional Requirements Checklist

```markdown
## Functional Acceptance Criteria

### Core Functionality
- [ ] {Feature} performs {action} when {condition}
      Test: {specific test case or pytest marker}

- [ ] {Error case} returns {expected response} when {invalid input}
      Test: {test case}

### Integration Points
- [ ] {System A} communicates with {System B} via {interface}
      Test: {integration test}

- [ ] {Data} flows from {source} to {destination} correctly
      Test: {end-to-end test}

### Edge Cases
- [ ] {Boundary condition} handled gracefully
      Test: {edge case test}

- [ ] {Concurrent scenario} produces correct result
      Test: {concurrency test}

### User Experience
- [ ] {Action} completes within {time} seconds
      Test: {performance benchmark}

- [ ] {Error message} provides actionable guidance
      Test: {UX validation}
```

### Non-Functional Requirements Checklist

```markdown
## Non-Functional Acceptance Criteria

### Performance
- [ ] {Operation} completes within {latency}ms at p95
      Measurement: {metric name or benchmark}

- [ ] System handles {throughput} requests/second
      Measurement: {load test command}

- [ ] Database queries execute within {time}ms
      Measurement: {query analysis tool}

### Security
- [ ] {Input} validated against {attack vector}
      Test: {security test}

- [ ] {Sensitive data} encrypted at rest and in transit
      Verification: {configuration audit}

- [ ] Authentication required for {protected resource}
      Test: {auth bypass test}

- [ ] OWASP Top 10 vulnerabilities mitigated
      Scan: {security scanner command}

### Reliability
- [ ] {Failure scenario} triggers {recovery mechanism}
      Test: {chaos engineering test}

- [ ] {Service} achieves {uptime}% availability
      Measurement: {monitoring dashboard}

- [ ] {Data operation} is idempotent
      Test: {retry test}

### Scalability
- [ ] {Component} scales horizontally to {N} instances
      Test: {scaling test}

- [ ] {Resource usage} grows O({complexity}) with load
      Measurement: {profiling data}

### Maintainability
- [ ] Code coverage >= {percentage}%
      Measurement: pytest --cov={module}

- [ ] Cyclomatic complexity <= {threshold}
      Measurement: {linting tool}

- [ ] All public APIs documented
      Verification: {doc generation tool}

### Observability
- [ ] {Critical operation} emits {metric/log/trace}
      Verification: {monitoring query}

- [ ] {Error condition} triggers {alert}
      Test: {alerting test}

- [ ] {Dashboard} displays {key indicators}
      Verification: {Grafana URL}
```

### Documentation Requirements Checklist

```markdown
## Documentation Acceptance Criteria

### Code Documentation
- [ ] All public functions have docstrings (Google/NumPy style)
- [ ] Complex algorithms include inline comments
- [ ] Type hints present for all function signatures
- [ ] Module-level docstring explains purpose

### API Documentation
- [ ] OpenAPI spec updated with new endpoints
- [ ] Request/response examples provided
- [ ] Error codes documented
- [ ] Authentication requirements specified

### User Documentation
- [ ] README.md updated with new features
- [ ] Configuration options documented in .env.example
- [ ] Deployment steps updated if changed
- [ ] Troubleshooting section includes new issues

### Architecture Documentation
- [ ] Design decisions captured in ADR (Architecture Decision Record)
- [ ] Sequence diagrams updated if flow changed
- [ ] Database schema ERD updated
- [ ] Component diagram reflects new services

### Operational Documentation
- [ ] Monitoring dashboards created/updated
- [ ] Alerting rules defined
- [ ] Runbook includes new failure modes
- [ ] Backup/restore procedures updated if needed
```

---

## Handoff Execution Process

### Step-by-Step Handoff Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                      HANDOFF INITIATION                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Step 1: Sender Prepares Work Package                           │
│ - Complete Pre-Handoff Checklist                               │
│ - Create YAML work package                                     │
│ - Run final validation (tests, lints, scans)                   │
│ - Capture context in CTX-00                                    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Step 2: Notify Receiving Agent                                 │
│ - Post work package to ~/.claude/context/handoffs/             │
│ - Notify via issue comment or direct message                   │
│ - CC ORC-00 for tracking                                       │
│ - Schedule handoff meeting if complexity > 4 hours             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Step 3: Receiver Reviews Work Package                          │
│ - Complete Receiving Agent Acceptance Checklist               │
│ - Validate artifacts accessible and complete                   │
│ - Verify dependencies met                                      │
│ - Identify any gaps or questions                              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────┴─────────┐
                    │                   │
                    ▼                   ▼
         ┌──────────────────┐  ┌──────────────────┐
         │ ACCEPTED         │  │ REJECTED         │
         └──────────────────┘  └──────────────────┘
                    │                   │
                    │                   ▼
                    │          ┌──────────────────┐
                    │          │ Document Gaps    │
                    │          │ Return to Sender │
                    │          └──────────────────┘
                    │                   │
                    │                   ▼
                    │          ┌──────────────────┐
                    │          │ Sender Remediates│
                    │          └──────────────────┘
                    │                   │
                    └───────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Step 4: Update Tracking Systems                                │
│ - Mark issue as "In Progress" by receiver                      │
│ - Update sprint board                                          │
│ - Log handoff in CTX-00                                        │
│ - Set coordination checkpoint                                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Step 5: Receiver Executes Work                                 │
│ - Follow acceptance criteria                                   │
│ - Report progress at checkpoints                               │
│ - Escalate blockers immediately                                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Step 6: Completion Validation                                  │
│ - Run acceptance criteria tests                                │
│ - Request sender verification                                  │
│ - QA-GUARD quality gate (if applicable)                        │
│ - Update context store                                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Step 7: Handoff Closure                                        │
│ - Mark issue complete                                          │
│ - Archive work package                                         │
│ - Capture lessons learned                                      │
│ - Notify stakeholders                                          │
└─────────────────────────────────────────────────────────────────┘
```

### Handoff States

Track handoff state in work package YAML:

```yaml
handoff:
  state: "pending_acceptance"  # Current state

  state_history:
    - state: "initiated"
      timestamp: "2025-11-27T14:30:00Z"
      by: "API-GOV"

    - state: "pending_acceptance"
      timestamp: "2025-11-27T14:35:00Z"
      by: "API-GOV"
      notes: "Work package submitted to API-CORE"
```

**Valid States**:
- `initiated` - Sender preparing work package
- `pending_acceptance` - Awaiting receiver review
- `rejected` - Receiver identified gaps, returned to sender
- `accepted` - Receiver accepted, work in progress
- `blocked` - Unexpected blocker encountered
- `pending_verification` - Work complete, awaiting validation
- `completed` - All acceptance criteria met, handoff closed
- `rolled_back` - Work reverted due to failure

### State Transition Rules

```
initiated → pending_acceptance → accepted → pending_verification → completed
                ↓                    ↓
            rejected              blocked
                ↓                    ↓
          (return to sender)    (escalate to ORC-00)
                                     ↓
                                rolled_back
```

---

## Coordination Checkpoints

### Checkpoint Timing

**1. Pre-Dependency Checkpoints**
- **When**: 1 business day before dependency needed
- **Purpose**: Confirm sender on track to meet deadline
- **Attendees**: Sender, receiver, ORC-00 (if critical path)
- **Duration**: 15 minutes
- **Outcomes**:
  - Sender confirms delivery date OR
  - Sender raises blocker, triggers escalation

**2. In-Flight Checkpoints**
- **When**: For work > 2 days duration, checkpoint every 2 days
- **Purpose**: Progress update, blocker identification
- **Attendees**: Receiver, sender (optional), ORC-00 (if behind schedule)
- **Duration**: 15 minutes
- **Outcomes**:
  - Confirm on track OR
  - Identify risks/blockers OR
  - Request assistance

**3. Pre-Completion Checkpoints**
- **When**: Before marking work "complete"
- **Purpose**: Validate acceptance criteria met
- **Attendees**: Receiver, sender, QA-GUARD (if quality gate required)
- **Duration**: 30 minutes
- **Outcomes**:
  - Acceptance criteria met → mark complete OR
  - Gaps identified → remediate OR
  - Acceptance criteria ambiguous → clarify with sender

**4. Emergency Checkpoints**
- **When**: Blocker identified that impacts timeline by > 1 day
- **Purpose**: Immediate resolution or escalation
- **Attendees**: Receiver, sender, ORC-00, SUP-00
- **Duration**: 30-60 minutes
- **Outcomes**:
  - Blocker resolved OR
  - Workaround identified OR
  - Escalation triggered OR
  - Rollback initiated

### End-of-Day Status Updates

For **critical path items** (those blocking other agents):

```markdown
## Daily Status Update Template

**Agent**: {Your agent ID}
**Work Package**: {handoff ID}
**Date**: {YYYY-MM-DD}

### Today's Progress
- {What was completed}
- {Tests that passed}
- {Artifacts created/updated}

### Tomorrow's Plan
- {Next actions}
- {Expected completion percentage}

### Blockers
- {Any blockers encountered}
- {Assistance needed}
- {Impact on timeline}

### Status
- [ ] On track for {expected completion date}
- [ ] At risk (explain)
- [ ] Blocked (escalate)

**Posted to**: Issue #{issue_number} comment
```

**Timing**: Posted by 5:00 PM local time or end of work session

---

## Escalation Procedures

### Escalation Levels

| Level | Trigger | Escalate To | Response SLA |
|-------|---------|-------------|--------------|
| **L1 - Blocker** | Cannot proceed, needs assistance | Sender agent or domain expert | 2 hours |
| **L2 - Timeline Risk** | Will miss deadline by > 1 day | ORC-00 (orchestrator) | 4 hours |
| **L3 - Quality Failure** | Acceptance criteria cannot be met | SUP-00 (quality supervisor) | 1 business day |
| **L4 - Security Issue** | Vulnerability or compliance violation | SEC-SHIELD + SUP-00 | Immediate |
| **L5 - System Outage** | Production impact | OPS-INFRA + ORC-00 + SUP-00 | Immediate |

### Escalation Process

#### L1 - Blocker Escalation

```markdown
## L1 Escalation: Blocker

**Escalated By**: {Agent ID}
**Work Package**: {handoff ID}
**Escalated To**: {Target agent or team}
**Escalated At**: {ISO timestamp}

### Blocker Description
{Clear description of what is blocking progress}

### Impact
- Affects: {which deliverables}
- Timeline impact: {estimated delay}
- Downstream impact: {which agents are blocked}

### Attempted Resolutions
1. {What you tried}
2. {What you tried}
3. {Why these didn't work}

### Assistance Needed
{Specific help required to unblock}

### Urgency
- [ ] Critical (blocks multiple agents)
- [ ] High (blocks this agent only)
- [ ] Medium (workaround available but suboptimal)
```

**File Location**: `~/.claude/context/escalations/YYYY-MM-DD-L1-{agent}-{issue}.md`

**Notification**: Post to issue + direct message to target agent

#### L2 - Timeline Risk Escalation

```markdown
## L2 Escalation: Timeline Risk

**Escalated By**: {Agent ID}
**Work Package**: {handoff ID}
**Escalated To**: ORC-00
**Escalated At**: {ISO timestamp}

### Timeline Status
- Original estimate: {duration}
- Work completed: {percentage}%
- Remaining work: {estimated duration}
- New completion date: {date}
- Original deadline: {date}
- **Delay**: {X days/hours}

### Root Cause
{Why timeline slipped}

### Mitigation Options
1. {Option 1 with tradeoffs}
2. {Option 2 with tradeoffs}
3. {Option 3 with tradeoffs}

### Recommendation
{Which option you recommend and why}

### Downstream Impact
{Which agents/features affected by delay}
```

**File Location**: `~/.claude/context/escalations/YYYY-MM-DD-L2-{agent}-{issue}.md`

**Notification**: Post to issue + tag ORC-00

#### L3 - Quality Failure Escalation

```markdown
## L3 Escalation: Quality Failure

**Escalated By**: {Agent ID}
**Work Package**: {handoff ID}
**Escalated To**: SUP-00
**Escalated At**: {ISO timestamp}

### Failed Acceptance Criteria
- [ ] {Criterion 1} - {why it cannot be met}
- [ ] {Criterion 2} - {why it cannot be met}

### Root Cause Analysis
{Why acceptance criteria are unachievable}

### Options
1. **Revise Acceptance Criteria**
   - Proposed changes: {new criteria}
   - Justification: {why this is acceptable}

2. **Extend Timeline**
   - Additional time needed: {duration}
   - What this enables: {how criteria will be met}

3. **Pivot Approach**
   - Alternative solution: {description}
   - Tradeoffs: {what changes}

### Recommendation
{Which option you recommend}

### Stakeholder Impact
{How this affects other agents/features}
```

**File Location**: `~/.claude/context/escalations/YYYY-MM-DD-L3-{agent}-{issue}.md`

**Notification**: Post to issue + tag SUP-00 + tag sender agent

#### L4 - Security Issue Escalation

```markdown
## L4 Escalation: Security Issue

**Escalated By**: {Agent ID}
**Work Package**: {handoff ID}
**Escalated To**: SEC-SHIELD, SUP-00
**Escalated At**: {ISO timestamp}
**Severity**: {Critical | High | Medium | Low}

### Vulnerability Description
{Description of security issue}

### Affected Components
- {Component 1}
- {Component 2}

### Attack Vector
{How this could be exploited}

### Current Exposure
- [ ] Production exposed
- [ ] Staging only
- [ ] Dev environment only
- [ ] Not yet deployed

### Immediate Actions Taken
1. {Action 1}
2. {Action 2}

### Recommended Remediation
{How to fix the vulnerability}

### Timeline for Fix
{Estimated time to remediate}
```

**File Location**: `~/.claude/context/escalations/YYYY-MM-DD-L4-SECURITY-{issue}.md`

**Notification**: Immediate notification to SEC-SHIELD + SUP-00 + ORC-00

#### L5 - System Outage Escalation

```markdown
## L5 Escalation: System Outage

**Escalated By**: {Agent ID}
**Escalated To**: OPS-INFRA, ORC-00, SUP-00
**Escalated At**: {ISO timestamp}
**Severity**: {P0 | P1 | P2}

### Outage Description
{What is down}

### User Impact
- Affected users: {number or percentage}
- Affected functionality: {description}
- Business impact: {revenue loss, SLA breach, etc.}

### Root Cause (if known)
{What caused the outage}

### Immediate Actions
1. {Action 1 - timestamp}
2. {Action 2 - timestamp}

### ETA to Resolution
{Estimated time}

### Communication Sent
- [ ] Status page updated
- [ ] Customer notification sent
- [ ] Internal stakeholders notified
```

**File Location**: `~/.claude/context/escalations/YYYY-MM-DD-L5-OUTAGE-{issue}.md`

**Notification**: All hands, immediate

### Escalation Response SLAs

| Level | Initial Response | Resolution Target |
|-------|-----------------|-------------------|
| L1 | 2 hours | 1 business day |
| L2 | 4 hours | 2 business days |
| L3 | 1 business day | 3 business days |
| L4 | Immediate (< 30 min) | Varies by severity |
| L5 | Immediate (< 15 min) | Varies by P-level |

**Response** = Acknowledgement + initial assessment
**Resolution** = Blocker removed or decision made

---

## Rollback Coordination

### When to Rollback

Rollback should be initiated when:

1. **Quality Gate Failure**: Acceptance criteria cannot be met within 2x original estimate
2. **Production Impact**: Deployment causes errors > 1% of requests
3. **Security Vulnerability**: Critical security issue discovered post-deployment
4. **Data Integrity**: Risk of data corruption or loss
5. **Dependency Cascade**: Rollback of dependent component necessitates this rollback

### Rollback Signaling

#### Initiating Rollback

```yaml
rollback:
  initiated_by: "API-CORE"
  work_package: "handoff-2025-11-27-api-gov-to-api-core-232"
  initiated_at: "2025-11-29T08:30:00Z"
  reason: "Production error rate spiked to 5% after deployment"
  severity: "high"  # critical | high | medium

  affected_components:
    - "POST /auth/login endpoint"
    - "JWT validation middleware"

  affected_agents:
    - agent: "API-GW"
      impact: "Needs to reroute /auth/* traffic to legacy endpoint"
      action_required: true

    - agent: "FRONT-UI"
      impact: "Token storage reverted to session cookies"
      action_required: true

    - agent: "DATA-CORE"
      impact: "None (auth tables unused in rollback state)"
      action_required: false

  coordination:
    - step: 1
      agent: "API-CORE"
      action: "Revert API code (git revert abc123)"
      status: "complete"
      completed_at: "2025-11-29T08:35:00Z"

    - step: 2
      agent: "OPS-INFRA"
      action: "Deploy rolled-back version"
      status: "in_progress"

    - step: 3
      agent: "API-GW"
      action: "Update routing rules"
      status: "pending"
      depends_on: "step_2"

    - step: 4
      agent: "FRONT-UI"
      action: "Deploy fallback UI code"
      status: "pending"
      depends_on: "step_2"

  verification:
    - metric: "Error rate"
      target: "< 0.1%"
      current: "5.2%"

    - metric: "Login success rate"
      target: "> 99%"
      current: "94.8%"

  post_rollback:
    - "Root cause analysis within 24 hours"
    - "Remediation plan within 48 hours"
    - "Redeployment timeline TBD after RCA"
```

**File Location**: `~/.claude/context/rollbacks/YYYY-MM-DD-{work-package-id}.yaml`

**Notification**: Immediate notification to all affected agents + ORC-00 + SUP-00

### Cross-Agent Rollback Procedures

When rollback affects multiple agents:

#### 1. Coordination Call
- **Initiated by**: Agent initiating rollback
- **Attendees**: All affected agents + ORC-00
- **Duration**: 30 minutes
- **Agenda**:
  - Confirm rollback necessity
  - Assign rollback steps to agents
  - Establish verification criteria
  - Set timeline

#### 2. Sequenced Rollback Execution

Execute rollback steps in dependency order:

```
Database rollback
      ↓
Backend API rollback
      ↓
API Gateway reconfiguration
      ↓
Frontend rollback
      ↓
Verification
```

**Coordination**: Each agent signals completion before next agent proceeds

#### 3. Verification Checkpoints

After each rollback step:

```yaml
verification_checkpoint:
  step: 2
  agent: "OPS-INFRA"
  action_completed: "Deployed rolled-back API version v1.2.3"
  timestamp: "2025-11-29T08:45:00Z"

  verification:
    - check: "API health check returns 200"
      result: "PASS"

    - check: "Error rate < 0.5%"
      result: "PASS"

    - check: "Login endpoint accessible"
      result: "PASS"

  proceed_to_next_step: true
  next_agent: "API-GW"
```

**Rule**: Do not proceed to next step until all verifications PASS

### State Restoration Requirements

When rolling back, each agent must restore:

#### Database (DATA-CORE)
- Rollback migrations: `alembic downgrade {revision}`
- Restore data if modified: `pg_restore {backup_file}`
- Verify schema integrity: Run schema validation queries

#### API (Backend agents)
- Revert code: `git revert {commit_sha}` or `git checkout {previous_tag}`
- Restore configuration: Revert environment variables
- Clear caches: Flush Redis, invalidate CDN

#### Frontend (FRONT-UI)
- Deploy previous version: `git checkout {previous_release}`
- Update API URLs if endpoints changed
- Clear browser storage if data structure changed

#### Infrastructure (OPS-INFRA)
- Revert infrastructure changes: Terraform/CloudFormation rollback
- Restore routing rules: Load balancer, API gateway configs
- Verify service discovery: Ensure services register correctly

### Post-Rollback Process

```markdown
## Post-Rollback Checklist

### Immediate (< 1 hour)
- [ ] All systems restored to stable state
- [ ] Verification criteria met
- [ ] Users notified (if customer-facing)
- [ ] Incident report started

### Short-term (< 24 hours)
- [ ] Root cause analysis completed
- [ ] Post-mortem scheduled
- [ ] Lessons learned captured in CTX-00

### Medium-term (< 48 hours)
- [ ] Remediation plan created
- [ ] Testing strategy updated
- [ ] Deployment checklist enhanced

### Long-term (< 1 week)
- [ ] Code fixes implemented
- [ ] Retested in staging
- [ ] Redeployment plan approved
```

---

## Agent-Specific Considerations

### ORC-00 (Orchestrator)
**Handoff Role**: Initiates parallel and staged handoffs
**Responsibilities**:
- Decompose epics into work packages
- Define interface contracts between agents
- Track critical path dependencies
- Escalate timeline conflicts

**Handoff Pattern**:
```yaml
# ORC-00 often creates 1:many handoffs
handoff:
  type: "parallel"
  from_agent: "ORC-00"
  to_agents:
    - "API-CORE"
    - "DATA-CORE"
    - "FRONT-UI"
  coordination: "Weekly sync meeting"
```

### CTX-00 (Context Manager)
**Handoff Role**: Archives handoff knowledge
**Responsibilities**:
- Store work package history
- Index decisions and lessons learned
- Surface relevant prior work
- Maintain handoff protocol

**Handoff Pattern**: Receives context from all agents, rarely initiates handoffs

### SUP-00 (Quality Supervisor)
**Handoff Role**: Quality gate enforcement
**Responsibilities**:
- Validate acceptance criteria before handoff
- Reject incomplete handoffs
- Escalation point for quality failures

**Handoff Pattern**: Validates sender's work before allowing handoff to proceed

### Domain Agents (API-CORE, DATA-CORE, FRONT-UI, etc.)
**Handoff Role**: Execute work packages
**Responsibilities**:
- Accept handoffs with validated checklists
- Report progress at checkpoints
- Escalate blockers promptly
- Document implementation decisions

**Handoff Pattern**: Sequential or staged, both sending and receiving

### Specialist Agents (SEC-SHIELD, QA-GUARD, DOC-WRITER)
**Handoff Role**: Review and validate
**Responsibilities**:
- Provide domain expertise
- Validate compliance (security, quality, documentation standards)
- Return findings to domain agents

**Handoff Pattern**: Receive for review, return with findings (not traditional handoff)

### DevOps Agents (OPS-INFRA, CI-AUTO, MON-WATCH)
**Handoff Role**: Deployment and operations
**Responsibilities**:
- Receive deployment-ready artifacts
- Validate infrastructure requirements met
- Execute rollbacks if needed
- Monitor post-deployment

**Handoff Pattern**: Receive from dev agents, return to dev agents if issues found

---

## Protocol Compliance

### Mandatory Requirements

All agents MUST:
1. Complete Pre-Handoff Checklist before initiating handoff
2. Use standardized YAML work package format
3. Define measurable acceptance criteria
4. Respond to handoff requests within 4 business hours
5. Report progress at scheduled checkpoints
6. Escalate blockers within 2 hours of identification
7. Archive completed handoffs in CTX-00

### Audit and Enforcement

**SUP-00 will audit handoff compliance monthly**, checking:
- Percentage of handoffs with complete checklists
- Average time from handoff initiation to acceptance
- Escalation response times
- Rollback execution times
- Acceptance criteria clarity and measurability

**Non-compliance consequences**:
- Warning after first occurrence
- Required remediation training after second occurrence
- Escalation to ORC-00 for systemic issues

### Protocol Updates

This protocol is a living document:
- **Owner**: CTX-00
- **Review Cadence**: Quarterly
- **Update Process**:
  1. Collect feedback from all agents
  2. CTX-00 proposes updates
  3. ORC-00 and SUP-00 approve
  4. Announce changes with 1-week notice
  5. Update effective date

**Version History**:
```yaml
versions:
  - version: "3.4"
    date: "2025-12-27"
    changes: "Session/Memory Handoff Improvements: Added tightened HOFF schema with fail-closed validation, SESSION_ID/PROJECT_KEY deterministic mapping, project landing snapshot integration"
    approved_by: ["CTX-00", "ORC-00", "SUP-00"]

  - version: "2.0"
    date: "2025-11-27"
    changes: "Major expansion: Added coordination checkpoints, escalation procedures, rollback coordination, acceptance criteria templates, agent-specific considerations"
    approved_by: ["CTX-00", "ORC-00", "SUP-00"]

  - version: "1.0"
    date: "2025-11-25"
    changes: "Initial protocol established"
    approved_by: ["ORC-00"]
```

---

## Quick Reference

### Handoff Decision Tree

```
Need to transfer work?
│
├─ Is it just advice? → NO HANDOFF (Consultation)
│
├─ Working together simultaneously? → NO HANDOFF (Collaboration)
│
├─ Transferring primary responsibility?
   │
   ├─ Sequential (A finishes, B starts) → SEQUENTIAL HANDOFF
   │
   ├─ Phased (A does part 1, B does part 2, A does part 3) → STAGED HANDOFF
   │
   ├─ Split work to multiple agents → PARALLEL HANDOFF
   │
   └─ Urgent blocker or security issue → EMERGENCY HANDOFF
```

### Handoff Checklist (Short Form)

**Sender**:
- [ ] Tests passing
- [ ] Docs updated
- [ ] Work package created
- [ ] Dependencies met
- [ ] Receiver notified

**Receiver**:
- [ ] Work package reviewed
- [ ] Artifacts accessible
- [ ] Acceptance criteria understood
- [ ] No blockers to start
- [ ] Handoff accepted

**Both**:
- [ ] Checkpoint scheduled
- [ ] Escalation path clear

### Key Files

- Work packages: `~/.claude/context/handoffs/YYYY-MM-DD-{from}-to-{to}-{issue}.yaml`
- Escalations: `~/.claude/context/escalations/YYYY-MM-DD-L{level}-{agent}-{issue}.md`
- Rollbacks: `~/.claude/context/rollbacks/YYYY-MM-DD-{work-package-id}.yaml`
- This protocol: `~/.claude/protocols/HANDOFF_PROTOCOL.md`

### Emergency Contacts

| Situation | Contact | Response Time |
|-----------|---------|---------------|
| Blocker | Sender agent or domain expert | 2 hours |
| Timeline risk | ORC-00 | 4 hours |
| Quality failure | SUP-00 | 1 business day |
| Security issue | SEC-SHIELD | Immediate |
| Production outage | OPS-INFRA | Immediate |
| Protocol question | CTX-00 | 1 business day |

---

**END OF PROTOCOL**

*For questions or protocol updates, contact CTX-00.*
