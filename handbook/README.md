# Agent Handbook

> **Version**: 1.0.0 | **CLI pinned**: 2.1.111 | **Last updated**: 2026-04-16
> **Audience**: every sub-agent in `~/.claude/agents/` + any human reviewing agent behaviour.

The handbook is the **single source of truth** for:
- Claude Code CLI flags and headless-session patterns.
- In-session skills, deferred tools, MCP, background tasks.
- Auto mode and `/loop` pacing (cache TTL, `ScheduleWakeup` vs `CronCreate`).
- Hive integration beyond the inline compliance stub in each agent.
- **Autonomous tool/skill selection** — the user should not have to name tools every session.

If you are an agent, you already ran the inline first-action steps from your preamble stub (SESSION_ID extract, session-folder verify, SPAWN emit). **Your mandatory next reads are `00-hive-protocol.md` and `07-decision-guide.md`.** The rest of the handbook is pull-on-demand.

---

## Decision tree — which file do I open?

| I want to… | Open |
|---|---|
| Understand the full hive checkpoint / event / recovery contract | `00-hive-protocol.md` |
| Spawn a headless sub-session with `claude -p` | `01-cli-headless.md` + `06-recipes.md` |
| Pick an in-session skill (`/simplify`, `/security-review`, …) | `02-in-session-toolbelt.md` → `07-decision-guide.md` |
| Load a deferred tool (`ScheduleWakeup`, `TaskCreate`, …) | `02-in-session-toolbelt.md` |
| Run a task on an interval or wake myself up later | `03-auto-and-loop.md` |
| Behave correctly under auto mode | `03-auto-and-loop.md` |
| Know what my specific agent is allowed to do | `04-capabilities-matrix.md` |
| Confirm a flag combination is safe before I invoke it | `05-safe-defaults.md` |
| Find a working example I can copy | `06-recipes.md` |
| Decide between two tools without asking the user | `07-decision-guide.md` |

---

## File index

| File | Purpose |
|---|---|
| `00-hive-protocol.md` | Full hive compliance reference — checkpoint schedule, event schemas, recovery, RESUME_PACKET, depth rules. |
| `01-cli-headless.md` | `claude -p` flags, output formats, session continuity, exit codes. |
| `02-in-session-toolbelt.md` | Skill tool, ToolSearch, deferred-tool catalog, MCP, `TaskCreate`/`Monitor`. |
| `03-auto-and-loop.md` | Auto mode contract, `/loop`, `ScheduleWakeup` vs `CronCreate`, cache-TTL pacing. |
| `04-capabilities-matrix.md` | Per-agent: headless-safe? loop-safe? pacing floors? MCP scopes? best skills/tools? |
| `05-safe-defaults.md` | Permission-preserving flag combos; forbidden patterns. |
| `06-recipes.md` | Copy-paste recipes (fan-out, headless test-00, resume-after-wake, loop-safe state). |
| `07-decision-guide.md` | **Autonomous tool/skill selection rules.** If → then → why. |

---

## Autonomy contract

> Agents decide their own tool/skill/CLI usage. The user should not have to say "use `/simplify`" or "use `ScheduleWakeup`" each session.

- Consult `07-decision-guide.md` before executing a task that has more than one reasonable approach.
- Use `AskUserQuestion` **only** for genuine requirement ambiguity (scope, acceptance, destination) — not for "which tool should I use?"
- Briefly surface the chosen approach in your user-facing update ("Running `/simplify` across the three files") but do not request permission for routine selection.
- When a non-obvious tool pairing works, write a `LESSON-TOOL-XXX` under `~/.claude/context/shared/lessons/` so `07-decision-guide.md` grows with experience.

---

## Link discipline

- Cross-file links use relative paths (`./07-decision-guide.md`), not absolute.
- Do not duplicate content between files — link instead.
- Flag tables live in `01-cli-headless.md` only. Other files reference.
- Event schema lives in `~/.claude/context/hive/EVENTS_NDJSON_SPEC.md`. `00-hive-protocol.md` references, does not duplicate.
- `CLAUDE.md` specialist-trigger routing is authoritative for agent selection; `04-capabilities-matrix.md` extends with handbook-specific columns only.

---

## How to update this handbook

1. Edit the target file. Keep every file scannable — tables and trigger→action lines beat prose.
2. Bump `CHANGELOG.md` with the date, handbook version, CLI version at validation, and a one-line note.
3. If a CLI flag was added/removed/renamed, update `01-cli-headless.md` + `CHANGELOG.md`.
4. If a new skill shipped in a CLI release, add it to `02-in-session-toolbelt.md` and cross-reference from `07-decision-guide.md` if it changes a decision rule.
5. Never inline content already in `CLAUDE.md`, `EVENTS_NDJSON_SPEC.md`, or an existing protocol in `~/.claude/protocols/`.
