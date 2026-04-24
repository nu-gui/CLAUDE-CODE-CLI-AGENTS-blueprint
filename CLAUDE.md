# CLAUDE.md

This file provides guidance to [Claude Code](https://claude.com/claude-code) when working with code in this repository.

**This is a blueprint.** After forking/cloning, edit this file to reflect your team's conventions, agent roster, and workflow rules.

---

## Execution Mode

### Default: Direct Execution

For most tasks (single-domain, single-agent), Claude Code should execute directly:

1. Match the request to the right specialist agent (see Specialist Triggers below)
2. Spawn the agent immediately
3. No ceremony — no dispatch-decision blocks, no session initialization for simple tasks

### When to use Orchestration mode

Spawn `orc-00-orchestrator` only when:

- The user explicitly says "orchestrate", "coordinate", or "sprint"
- The task requires 3+ specialist domains working together
- The task references sprint docs or batches of 5+ GitHub issues
- Multi-agent coordination is explicitly requested

The orchestrator owns the full dispatch protocol (session init, hive artifacts, dispatch decisions). That lives inside `agents/orc-00-orchestrator.md`.

## Specialist Triggers (Direct Spawn)

| Pattern | Agent |
|---|---|
| API, endpoint, REST, GraphQL, backend | `api-core` |
| OAuth, JWT, auth, rate limit, API security | `api-gov` |
| Component, frontend, React, Vue, CSS, UI | `ui-build` |
| User flow, UX, wireframe, journey | `ux-core` |
| Database, schema, ETL, SQL, migration | `data-core` |
| ML, model, training, prediction | `ml-core` |
| CI/CD, Kubernetes, Docker, deploy, infra | `infra-core` |
| Dashboard, KPI, metrics, analytics | `insight-core` |
| SIP, RAN, IMS, SS7, network design | `tel-core` |
| NOC, CDR, billing, provisioning, fraud | `tel-ops` |
| Run tests, test suite, coverage, scan | `test-00-test-runner` |
| Documentation, README, API docs, runbook | `doc-00-documentation` |
| Review, approve, validate, release, QA | `sup-00-qa-governance` |
| Plan, roadmap, epic, story, sprint, backlog | `plan-00-product-delivery` |
| Product discovery, feature gap scan, roadmap alignment | `prod-00-product-discovery` |
| Email, notify, communicate, message | `com-00-inbox-gateway` |

## GitHub Issue References

When the user references `#123` or similar:

1. Fetch with `gh issue view 123 --json title,body,labels,assignees`
2. Route to the specialist that matches the content/labels
3. Include the fetched context in the agent prompt

## Loop Detection

If a prompt contains nested agent spawn indicators (`depth N/M` where `N >= M`), HALT and report.

---

# Shared Context System

All agents read from and write to the **shared context hive** under `${HOME}/.claude/context/`:

```
${HOME}/.claude/context/
├── hive/
│   ├── events.ndjson            # Append-only event stream
│   ├── sessions/                # Session folders (managed by orc-00)
│   └── audits/                  # Audit reports
├── shared/                      # Cross-project knowledge
│   ├── patterns/                # PATTERN-XXX files
│   ├── lessons/                 # LESSON-XXX files
│   └── decisions/               # DEC-XXX files
├── projects/                    # Project-specific context
│   └── {project-name}/
│       └── landing.yaml         # Project state (CTX-00 only)
└── index.yaml                   # Master index
```

Runtime state under `${HOME}/.claude/context/hive/sessions/`, `active/`, `completed/`, `events.ndjson`, and `projects/` is `.gitignore`'d by default. Only cross-project framework artefacts (patterns, lessons, decisions) are version-controlled.

See [`protocols/`](protocols/) for the full protocol set, and [`handbook/`](handbook/) for the agent operational reference.

---

# Workflow Modes

| Mode | Activation | Use Case |
|---|---|---|
| **direct** | default | quick fixes, single changes, most tasks |
| **issue-first** | `WORKFLOW_MODE: issue-first` or sprint/milestone keywords | sprint work, team projects |
| **minimal** | `WORKFLOW_MODE: minimal` | research, exploration |

### Issue-First Mode (customize for your tracker)

When active: verify `gh` auth, create GitHub issues, branch-per-issue, milestone assignment, PRs target your default branch.

```bash
gh issue create --title "[API-CORE] Fix bug" --milestone "Sprint-YYYY-WXX"
git checkout -b 118/fix-bug
gh pr create --title "[#118] Fix bug"
```

---

# Agent Roster

### Coordination Layer (7)

| Agent | `subagent_type` | Purpose |
|---|---|---|
| ORC-00 | `orc-00-orchestrator` | Multi-agent coordination |
| SUP-00 | `sup-00-qa-governance` | QA and release approval |
| PLAN-00 | `plan-00-product-delivery` | Sprint and roadmap |
| PROD-00 | `prod-00-product-discovery` | Feature-gap scan + issue creation |
| COM-00 | `com-00-inbox-gateway` | External communications |
| CTX-00 | `ctx-00-context-manager` | Context persistence |
| DOC-00 | `doc-00-documentation` | Documentation |

### Execution Layer (11)

| Agent | `subagent_type` | Purpose |
|---|---|---|
| API-CORE | `api-core` | Backend APIs |
| API-GOV | `api-gov` | API security |
| UX-CORE | `ux-core` | UX strategy |
| UI-BUILD | `ui-build` | Frontend |
| TEL-CORE | `tel-core` | Telecom architecture |
| TEL-OPS | `tel-ops` | Telecom operations |
| DATA-CORE | `data-core` | Data engineering |
| ML-CORE | `ml-core` | Machine learning |
| INFRA-CORE | `infra-core` | Platform / DevOps |
| INSIGHT-CORE | `insight-core` | BI / Analytics |
| TEST-00 | `test-00-test-runner` | Test execution |

Every agent is a markdown file under [`agents/`](agents/). Tune the triggers, tools, effort, and permission mode per agent to match your team's risk appetite.

---

# Pipeline Infrastructure (optional — keep, adapt, or remove)

This blueprint ships with two automated pipelines under `scripts/` + `config/`:

- **daytime-harrier** — daylight sweeps: product discovery, sprint refresh, shallow dispatch
- **nightly-puffin** — overnight execution: selector → plan → specialist waves → review → deploy → digest

Both are fully documented in [`docs/nightly-puffin.md`](docs/nightly-puffin.md) and [`docs/daytime-harrier.md`](docs/daytime-harrier.md). Configure them via `config/nightly-schedule.yaml` + `config/nightly-repo-profiles.yaml` (templates under `config/*.template`).

If you don't want automation, you can delete everything under `scripts/nightly-*`, `scripts/morning-*`, `scripts/evening-*`, `scripts/product-discovery.sh`, `scripts/doc-hygiene-scan.sh`, and the corresponding `config/*.template` files. The core agent framework does not depend on the pipeline.

---

# Handbook

The operational reference for every sub-agent — CLI headless (`claude -p`), in-session Skills, deferred tools, auto-mode / `/loop` pacing, and the hive protocol beyond the compliance stub — lives in [`handbook/`](handbook/):

- `handbook/README.md` — decision tree + file index
- `handbook/07-decision-guide.md` — autonomous tool/skill selection rules
- `handbook/04-capabilities-matrix.md` — per-agent capabilities
- `handbook/00-hive-protocol.md` — full hive compliance reference

---

# Customization Checklist

After forking this blueprint, edit in this order:

1. **`.env`** — `GITHUB_ORG`, `GITHUB_USER`, `TIMEZONE`
2. **`config/*.template`** — copy to live form, customize your repo list and schedule
3. **This file (`CLAUDE.md`)** — your team's branching rules, agent triggers you want to adjust
4. **`agents/*.md`** — add/remove agents to match your domains
5. **`.github/CODEOWNERS`** — your GitHub handles
6. **`settings.json.template` → `settings.json`** — hook paths (usually default is fine)

See [`CUSTOMIZATION.md`](CUSTOMIZATION.md) for the full walkthrough and [`TEMPLATE_VARIABLES.md`](TEMPLATE_VARIABLES.md) for every `${VAR}` placeholder.

---

# Version

This file is part of a blueprint regenerated from upstream. When you fork, drop this line and track your own version in a way that makes sense for your team.
