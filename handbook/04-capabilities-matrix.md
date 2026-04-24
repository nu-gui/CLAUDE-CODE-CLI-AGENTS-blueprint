# 04 — Capabilities Matrix

> Per-agent rules: what can I spawn, what can I invoke, how fast should I loop, which MCP scopes do I own.
> Derived from agent frontmatter + domain. If a row and an agent's frontmatter disagree, **frontmatter wins** — update the matrix to match.

**Authoritative routing table** (which agent for which task) lives in `~/.claude/CLAUDE.md` § "Specialist Triggers". This matrix extends it with handbook-specific columns only; it does not re-assert routing.

---

## Matrix

Columns:
- **HS** = may spawn headless `claude -p` children
- **PM** = default `permissionMode`
- **LS** = safe to run inside `/loop`
- **WU min** = minimum `ScheduleWakeup` `delaySeconds` floor for this agent (cache-aware)
- **MCP** = MCP scopes the agent may call
- **Best skills / tools** = primary Skill / deferred-tool picks for this agent's domain

### Coordination layer

| Agent | HS | PM | LS | WU min | MCP | Best skills / tools |
|---|---|---|---|---|---|---|
| `orc-00-orchestrator` | **YES** (primary fan-out caller) | default | YES (drives cron jobs) | 1200 s (orchestration is idle-heavy) | Gmail, Calendar (notifications only) | `Skill(schedule)`, `CronCreate`, `ScheduleWakeup`, `TaskCreate`, `AskUserQuestion`, fan-out `claude -p` |
| `sup-00-qa-governance` | YES (only for isolated review probes) | plan | NO (one-shot gate) | n/a | none | `Skill(security-review)`, `Skill(ultrareview)`, `Skill(simplify)`, `WebFetch` |
| `plan-00-product-delivery` | NO | plan | YES (sprint ticks) | 1800 s | Calendar (sprint events), Gmail (notifications) | `Skill(schedule)`, `CronCreate` (`0 9 * * 1`), `AskUserQuestion`, `WebFetch`, `TaskCreate` |
| `com-00-inbox-gateway` | NO | default | YES (inbox polling) | 600 s | Gmail (full), Calendar (read) | Gmail MCP, `WebFetch`, `PushNotification`, `TaskCreate` |
| `ctx-00-context-manager` | YES (for session-rehydrate fan-out) | default | YES (maintenance) | 1800 s | none | `TaskCreate`, `ScheduleWakeup`, `Monitor`, `WebFetch` (rare) |
| `doc-00-documentation` | NO | default | NO | n/a | none | `Skill(init)`, `WebFetch`, `WebSearch` |

### Execution layer

| Agent | HS | PM | LS | WU min | MCP | Best skills / tools |
|---|---|---|---|---|---|---|
| `api-core` | YES (fan-out integration tests) | default | NO | n/a | none | `Skill(simplify)`, `Skill(security-review)`, `Skill(claude-api)` (if touching Anthropic SDK), `TaskCreate`, `Monitor` |
| `api-gov` | NO (review-only) | plan | NO | n/a | none | `Skill(security-review)`, `Skill(ultrareview)`, `WebFetch`, `WebSearch` |
| `ui-build` | YES (parallel design-system audits) | default | NO | n/a | none | `Skill(simplify)`, `Skill(security-review)`, `TaskCreate`, `Monitor`, `EnterWorktree` |
| `ux-core` | NO | plan | NO | n/a | none | `AskUserQuestion`, `WebFetch`, `WebSearch` |
| `tel-core` | NO | plan | NO | n/a | none | `WebFetch`, `WebSearch`, `Skill(init)` |
| `tel-ops` | YES (NOC probes, multi-switch fan-out) | default | YES (NOC watches) | 600 s | none | `CronCreate`, `ScheduleWakeup`, `TaskCreate`, `Monitor`, `WebFetch` |
| `data-core` | YES (pipeline probe fan-out) | default | YES (data-quality ticks) | 1200 s | none | `CronCreate`, `TaskCreate`, `Monitor`, `Skill(simplify)` |
| `ml-core` | YES (training/inference probes) | default | YES (training watches) | 1800 s | none | `CronCreate`, `ScheduleWakeup`, `TaskCreate`, `Monitor` |
| `infra-core` | YES (multi-env deploy probes) | default | YES (deploy watches) | 600 s | none | `CronCreate`, `ScheduleWakeup`, `TaskCreate`, `Monitor`, `Skill(security-review)` |
| `insight-core` | NO | plan | YES (scheduled reports) | 1800 s | Calendar (report cadence), Gmail (send) | `Skill(schedule)`, `CronCreate`, `WebFetch`, `TaskCreate` |
| `test-00-test-runner` | **YES** (primary fan-out caller) | default | YES (suite watches) | 270 s (short-cycle tests) | none | fan-out `claude -p`, `TaskCreate`, `Monitor`, BATCH events, `Skill(security-review)` |

---

## Defaults explained

- **HS = YES** means this agent's role routinely benefits from isolating work into a fresh sub-session. HS = NO does not forbid headless spawns — it means don't reach for it by default.
- **LS = YES** means the agent's work naturally repeats on a cadence (deploys, data pipelines, NOC watches, sprint ticks, inbox polling). LS = NO agents are one-shot responders and should not be in `/loop`.
- **WU min** is cache-aware. Floors ≥ 1200 s mean the workload is idle-heavy and one cache miss per ~20 min is acceptable. Floors at 270 s mean "stay in cache" is the right choice because the loop is genuinely active.
- **PM** = `plan` agents require user approval for mutations. They may still *analyse* autonomously and emit `AskUserQuestion` for a plan-approval — but they cannot Edit/Write/Bash without explicit consent unless `--permission-mode` is overridden in a `claude -p` child (which they generally should not do).
- **MCP**: any scope not listed means the agent should not call MCP tools in that category. Frontmatter `tools:` is authoritative when present.

---

## Depth limits (recursion)

| Agent | Max depth it may spawn to |
|---|---|
| `orc-00-orchestrator` | 4 |
| `test-00-test-runner` | 3 |
| `ctx-00-context-manager` | 2 |
| `api-core` / `data-core` / `ml-core` / `infra-core` / `tel-ops` / `ui-build` | 2 |
| `sup-00-qa-governance` | 1 (isolated review probes only) |
| `api-gov` / `ux-core` / `tel-core` / `insight-core` / `plan-00` / `com-00` / `doc-00` | 0 (may not spawn) |

When you spawn a child, pass `depth N+1/M` in the child's prompt (where `M` is the max-depth from this table). Children enforce the limit in their preamble stub.

---

## How to update this matrix

1. Read the agent's frontmatter (`name`, `permissionMode`, `tools`, `disallowedTools`).
2. Cross-check `HS` and `LS` columns against the agent body's stated responsibilities.
3. Update the matrix; bump `./CHANGELOG.md`.
4. If a new skill / tool / MCP scope was added upstream, update the "Best skills / tools" cell and any affected decision rules in `./07-decision-guide.md`.
