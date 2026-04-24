# 07 — Decision Guide (Autonomous Tool / Skill Selection)

> **The user should not have to name tools, skills, or CLI patterns every session.** Your job is to pick the right fit for the task and execute.
> Format: `if trigger → then action → why`. Table-first so you can scan fast.

Each section answers one question. Skim the trigger column; when you find your situation, do the action and move on.

---

## 1. "How should I structure my work?"

| If | Then | Why |
|---|---|---|
| Task is a simple, 1–2 step change | Just do it. No TaskCreate. | Overhead > value. |
| Task is 3+ discrete steps | `TaskCreate` for each; mark `in_progress` as you start, `completed` as you finish. | User can see progress; future-you can resume. |
| Task spans multiple files or domains | Split into `TaskCreate` items **and** emit `PROGRESS` events at milestones. | Hive audit needs the trail. |
| Task is orchestration across ≥ 3 specialists | Escalate to `orc-00-orchestrator`. Do not DIY. | Coordination is that agent's job; you'll do it worse. |

---

## 2. "I need to validate code I (or someone) just changed"

| If | Then | Why |
|---|---|---|
| Small diff (1–3 files), want a second pass | `Skill(simplify)` | 3 parallel reviewers, fast, applies fixes. |
| Pre-merge security concern | `Skill(security-review)` | Focused on injection / auth / data exposure. |
| Large branch or full PR | `Skill(ultrareview)` (or `/ultrareview <PR#>`) | Cloud-based multi-agent critique; built for breadth. |
| Post-refactor sanity | `Skill(simplify)` first; `Skill(security-review)` if auth/data involved | Cheap-first, expensive-second. |
| "Review this PR comment thread" | `Bash(gh pr view <#> --comments)` then synthesise. Don't use `/pr-comments` (**removed 2.1.91**). | Skill no longer exists. |

**Do not** ask the user "should I run /simplify?" — the decision is yours.

---

## 3. "I need a fresh / isolated context for part of this work"

| If | Then | Why |
|---|---|---|
| Independent probe (read-only) | `claude -p … --bare --allowedTools "Read,Grep,Glob" --no-session-persistence` | Smallest blast radius; see `./05-safe-defaults.md`. |
| 3–10 independent probes in parallel | Fan-out with N `claude -p` calls, each with own `--session-id` | Keeps parent context clean; see `./06-recipes.md`. |
| Need the parent's conversation history | **Don't go headless.** Use Task tool / Agent tool. | Headless children lose parent history. |
| Need sibling agent with shared hive state | Task tool with `subagent_type` (or `claude -p` that re-passes `SESSION_ID`/`depth`) | Hive integration is what you want, not isolation. |
| Cross-repo read | `claude -p … --add-dir /other/repo --allowedTools Read,Grep,Glob` | Read-only cross-project exploration. |

---

## 4. "Something is long-running or I need to wait"

| If | Then | Why |
|---|---|---|
| Process in-session you just started | `Bash(..., run_in_background=true)` + `Monitor` with a specific condition | No polling, no sleeping, harness notifies you. |
| External state you can't control (CI run, user review, deploy) | `ScheduleWakeup` at an appropriate `delaySeconds` | Self-paced; reads cache rules in `./03-auto-and-loop.md`. |
| Repeating on a wall-clock cadence | `CronCreate` with `<<autonomous-loop>>` sentinel | Persistent across sessions. |
| "Every 5 minutes" is the cadence | **Drop to 270 s (stay cached) or jump to 1200 s.** Never 300 s. | Cache miss + short wait is worst-of-both. |
| You're inside `/loop <prompt>` (no interval) | Decide each turn: more work → `ScheduleWakeup` with correct delay; done → omit. | Dynamic pacing is your job. |
| You're inside `/loop 5m <prompt>` | Don't call `ScheduleWakeup` or `CronCreate`. Just work. | Harness re-fires. |

---

## 5. "I need external information"

| If | Then | Why |
|---|---|---|
| Public doc, API ref, or standard | `WebFetch` the canonical URL | Cheapest authoritative source. |
| Anthropic SDK / Claude API code | `Skill(claude-api)` (auto-activates on `anthropic` import) | Has prompt-caching patterns baked in. |
| "What does X mean" / topical research | `WebSearch` (small) or `WebFetch` specific URLs | Search for breadth, fetch for depth. |
| Large-context research (>10 URLs) | Fan-out `claude -p` children with `--allowedTools Read,WebFetch` and collect results | Keep parent context clean. |
| Internal / authenticated URLs | Verify user authorisation first; never assume | Treat URLs like credentials. |

---

## 6. "I need to communicate or ask the user something"

| If | Then | Why |
|---|---|---|
| Choice between 2–4 well-defined options affecting scope | `AskUserQuestion` | Structured, unblocks quickly. |
| Open-ended design question | Propose 1–2 options in text, ask for redirect — not `AskUserQuestion` | Free-text conveys tradeoffs better. |
| "Which tool should I use?" | **Never ask. Decide.** | Autonomy contract. |
| External ticket / email / Slack | Route through `com-00-inbox-gateway`; do not DM directly | Single gateway; audit trail. |
| Mobile notification about completion | `PushNotification` (if user configured Remote Control) | Works when user is away from terminal. |
| Status during autonomous run | Emit `PROGRESS` event; do not text-spam | Events are the audit trail. |

---

## 7. "I need to schedule or automate something"

| If | Then | Why |
|---|---|---|
| One-off delayed action | `ScheduleWakeup` | Lightweight, single wake. |
| Recurring cadence (daily, hourly, weekly) | `CronCreate` + `Skill(schedule)` | Persistent across sessions. |
| Kick off remote agent (web session) | `RemoteTrigger` | Built for that. |
| Skill-level scheduling interaction | `Skill(schedule)` | User-visible management surface. |

---

## 8. "I'm about to touch settings, permissions, or the harness"

| If | Then | Why |
|---|---|---|
| User says "allow X" / "set env var" / "add hook" | `Skill(update-config)` | Authoritative for `settings.json`. |
| Reduce permission prompts | `Skill(less-permission-prompts)` | Scans transcript, proposes allowlist. |
| Rebind keys | `Skill(keybindings-help)` | Handles `~/.claude/keybindings.json`. |
| Change theme or model only | `/config` | Don't drag in `update-config` for trivia. |

---

## 9. "I'm writing code"

| If | Then | Why |
|---|---|---|
| Adding a function that looks like existing code | Reuse. Don't invent abstractions on first sight. | YAGNI + consistency. |
| Tempted to add a comment explaining what | Don't. Rename identifiers instead. | Good names replace most comments. |
| Tempted to add error handling "just in case" | Don't. Handle at boundaries, trust internal code. | Reduces noise. |
| Tempted to add backwards-compat shims | Don't. Just change the code. | No duplicate paths to maintain. |

---

## 10. "I'm about to take a risky action"

| If | Then | Why |
|---|---|---|
| `rm -rf`, dropping DB tables, killing prod processes | **Ask the user first.** Auto mode is not a license. | Irreversible + shared state. |
| Force-push to `main` | Refuse unless explicitly authorised. | Root-trust operation. |
| Post to Slack / email / ticket | Only if user directed. | Data exfiltration rule. |
| Share a secret | Only to a destination the user explicitly authorised for that specific secret. | Credential discipline. |
| Use `--dangerously-skip-permissions` in a sub-agent | **Never.** | Forbidden (see `./05-safe-defaults.md`). |

---

## 11. "I'm managing the hive / session state"

| If | Then | Why |
|---|---|---|
| I modified a file | Write a checkpoint line to `agents/<id>/checkpoints.ndjson` | Crash recovery. |
| I finished my task | Emit `COMPLETE`; update `RESUME_PACKET.md` | Audit trail + handoff. |
| I'm blocked | Emit `BLOCKED` with `reason` + `depends_on` | SUP-00 audits. |
| 10+ events per second | Use `BATCH` event | Reduces I/O. |
| I need another agent's work to continue | Check their checkpoints first; if missing, emit `BLOCKED` | Don't guess at their state. |

---

## 12. "I'm not sure which agent should do this"

| If | Then | Why |
|---|---|---|
| Task matches 1 specialist in `CLAUDE.md` trigger table | Spawn that specialist directly | No orchestrator needed. |
| Task matches 3+ specialists | Spawn `orc-00-orchestrator` | That's what it's for. |
| Task is ambiguous | `AskUserQuestion` with domain options | Scope clarification is valid. |
| User said "orchestrate" / "sprint" / "coordinate" | `orc-00-orchestrator` regardless of count | Explicit signal. |

---

## Anti-patterns — things that should never happen

- Asking "should I use /simplify or /security-review?" — pick one.
- Writing a plan document when none was requested.
- Chaining `sleep` in Bash for >60 s — use `Monitor` or `ScheduleWakeup`.
- Adding `--dangerously-skip-permissions` to a child session.
- Posting to Slack without the user explicitly authorising both the message and the channel.
- Modifying `main` directly (branch workflow in `CLAUDE.md` is mandatory).
- Batching `SPAWN` / `COMPLETE` / `FAILED` into a `BATCH` event.
- Calling `AskUserQuestion` in `/loop` iterations — emit `BLOCKED` instead.

---

## When the guide doesn't cover it

1. Read `./04-capabilities-matrix.md` for your agent's defaults.
2. Read the catalog in `./02-in-session-toolbelt.md`.
3. Look in `~/.claude/context/shared/lessons/LESSON-TOOL-*.md` for community experience.
4. Make a reasonable choice and act. **If it works, record a new `LESSON-TOOL-XXX`** so the next agent doesn't have to re-derive.
