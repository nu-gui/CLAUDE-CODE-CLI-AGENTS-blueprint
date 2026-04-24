# 02 — In-Session Toolbelt

> Everything you can invoke without leaving the current session: the `Skill` tool, the deferred-tool catalog (`ToolSearch`), MCP servers, background tasks, and agent-to-user / agent-to-scheduler tools.
> **Decide what to use in `./07-decision-guide.md`.** This file is the catalog.

---

## 1. The `Skill` tool

The `Skill` tool invokes a skill by name (the same as `/skill-name` in the user prompt). Skills are **prompt playbooks** — invoking one loads its instructions into the conversation and can trigger tool use.

### Bundled skills (current CLI)

| Skill | When |
|---|---|
| `simplify` | Review recent changed code in parallel (3 reviewers), aggregate, apply fixes. Ideal after a multi-file edit. |
| `security-review` | Analyse branch diff for injection, auth, data-exposure issues. Pre-merge. |
| `ultrareview` | Comprehensive cloud-based multi-agent review (2.1.111+). Use for PRs or large branches. Optional `<PR#>`. |
| `review` | **Deprecated** — install the `code-review` plugin instead. |
| `debug` | Turn on debug logging mid-session and troubleshoot. |
| `loop` | Run a prompt on a recurring interval (`/loop 5m /foo`) or self-paced (`/loop /foo`). Details in `./03-auto-and-loop.md`. |
| `schedule` | Create, update, list, or run scheduled remote agents (cron triggers). Details in `./03-auto-and-loop.md`. |
| `claude-api` | Load Claude API / Anthropic SDK reference for the project's language; auto-activates when `anthropic` / `@anthropic-ai/sdk` is imported. |
| `batch` | Parallel large-scale changes across codebase via worktrees + PRs. |
| `init` | Initialise a new `CLAUDE.md` for a codebase. |
| `update-config` | Configure the harness via `settings.json` (permissions, env vars, hooks, theme/model). |
| `less-permission-prompts` | Scan transcripts, add prioritised allowlist to `.claude/settings.json` (2.1.111+). |
| `keybindings-help` | Customise keyboard shortcuts and `~/.claude/keybindings.json`. |

### Invocation

```
Skill(skill="simplify", args="focus=auth")
```

Only invoke a skill that appears in the session's available-skills list (shown in system reminders). Do not guess names. Skills already loaded (indicated by a `<command-name>` tag in the current turn) should not be re-invoked.

---

## 2. The deferred-tool catalog (`ToolSearch`)

Many tools are not loaded at session start to save schema tokens. They are listed by name in system reminders but their schemas must be fetched before use:

```
ToolSearch(query="select:ScheduleWakeup,CronCreate", max_results=5)
```

Query forms:
- `select:<name>[,<name>...]` — exact fetch by name.
- `keyword1 keyword2` — best-match search.
- `+require keyword` — must include `require` in the name, rank by keyword.

Once `ToolSearch` returns the schema, the tool is callable like any built-in.

### Deferred-tool highlights (by category)

**Scheduling & looping** — see `./03-auto-and-loop.md`:
- `ScheduleWakeup` — schedule self-wake for dynamic `/loop` pacing.
- `CronCreate` / `CronList` / `CronDelete` — persistent cron-style triggers.
- `RemoteTrigger` — run / schedule remote agents.

**Plan mode / user interaction**:
- `EnterPlanMode` / `ExitPlanMode` — enter/leave plan mode programmatically.
- `AskUserQuestion` — structured question to the user. **Use only for genuine requirement ambiguity**, never "which tool should I use?"
- `PushNotification` — mobile push (when Remote Control is on and user opted in).

**Background work**:
- `TaskCreate` / `TaskList` / `TaskGet` / `TaskUpdate` / `TaskOutput` / `TaskStop` — in-session todo tracking (use for 3+-step work).
- `Monitor` — stream stdout from a background process (pairs with Bash `run_in_background`).

**External data**:
- `WebFetch` — fetch a URL and parse (CSS/script stripped — 2.1.105+).
- `WebSearch` — run a web search.

**Worktrees**:
- `EnterWorktree` / `ExitWorktree` — switch into/out of a git worktree.

**Notebooks**:
- `NotebookEdit` — edit Jupyter cells.

**MCP tools** — dynamically registered per server (see §4 below).

---

## 3. Background tasks (`TaskCreate` + `Monitor`)

Use for 3+ step work so the user can see progress and so future you can check status:

```
TaskCreate(subject="Run test suite", activeForm="Running test suite", description="npm test && pytest")
```

Update status as you work: `pending` → `in_progress` → `completed`. Never batch completions — mark done the moment the work is done.

For a long-running shell command (build, test, deploy), prefer:
1. `Bash(..., run_in_background=true)` — start the process.
2. `Monitor(shell_id=<id>, condition="until grep -q 'ready' <logfile>")` — wait for the signal without polling.
3. Do not sleep. Do not chain short sleeps. If the process completes before you check, the harness notifies you.

---

## 4. MCP (Model Context Protocol)

MCP servers expose their own tools with the prefix `mcp__<server>__<tool>`. Current servers visible to agents include:

- `mcp__claude_ai_Gmail__*` — Gmail (list labels, search threads, create draft, label).
- `mcp__claude_ai_Google_Calendar__*` — Calendar (list/create/update events, suggest time, respond).

Rules:
- **Only use MCP tools when the task requires them.** Most engineering work does not.
- Respect MCP scope: an agent given `tools:` in its frontmatter cannot call MCP tools not in that list. `--strict-mcp-config` locks the set for headless children.
- MCP calls can leak sensitive data. Verify the user has authorised both the action and the destination before calling.
- A server that fails to connect emits a `plugin_errors` entry on the `init` frame; check it before relying on MCP tools.

---

## 5. Anti-patterns (in-session)

- **Polling in a sleep loop** — use `Monitor` or `ScheduleWakeup`.
- **Manual `/skill-name` in text instead of the `Skill` tool** — the model cannot invoke a skill by echoing it; call the tool.
- **Calling a deferred tool before `ToolSearch`** — fails with `InputValidationError`; fetch the schema first.
- **`WebFetch` on internal / authenticated URLs without explicit user authorisation** — treat URLs like credentials.
- **`AskUserQuestion` for routine tool selection** — forbidden. Decide autonomously per `./07-decision-guide.md`.
- **Chaining MCP calls without error checks** — partial success can leave external state mid-change.

---

## 6. Quick-reference: "I need to…"

| Intent | First reach |
|---|---|
| Validate my recent code changes | `Skill(simplify)` |
| Security-review before merge | `Skill(security-review)` or `/ultrareview` for larger PRs |
| Re-check a build I started 10 min ago | `Monitor` (if started with `run_in_background`) or `ScheduleWakeup` |
| Track multi-step work | `TaskCreate` |
| Fetch external API docs | `WebFetch` (or `Skill(claude-api)` for Anthropic SDK) |
| Search the web | `WebSearch` |
| Ask user a multi-choice requirement question | `AskUserQuestion` |
| Run a recurring job | `CronCreate` + `<<autonomous-loop>>` sentinel (`./03-auto-and-loop.md`) |
| Pace my own loop | `ScheduleWakeup` + `<<autonomous-loop-dynamic>>` sentinel |
| Work in a git worktree | `EnterWorktree` / `ExitWorktree` or `claude -p -w <name>` |
| Edit a Jupyter notebook | `NotebookEdit` |
| Notify user on mobile | `PushNotification` (if configured) |

For a deeper decision: `./07-decision-guide.md`.
