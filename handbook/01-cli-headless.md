# 01 — CLI Headless (`claude -p`)

> **CLI pinned**: 2.1.111. Flag-drift log in `./CHANGELOG.md`.
> **Use for**: spawning isolated Claude sub-sessions from your agent to fan out work, probe state, or run a bounded analysis without contaminating the parent conversation.
> **Do not use for**: spawning another in-session sub-agent — that is the Task tool / Agent tool, not this.

---

## When headless beats Task-tool spawn

| Situation | Prefer |
|---|---|
| Need a completely fresh context, no parent history | `claude -p` |
| Work is bounded, deterministic, and emits structured output | `claude -p --output-format json` |
| Task belongs to an entirely different repo / project | `claude -p --add-dir <path>` |
| Fan-out across 3–10 probes, each independent | parallel `claude -p` (see `./06-recipes.md`) |
| Task is a sibling agent that should inherit hive session state | Task tool with `subagent_type` |
| Work needs to read parent conversation to decide | Task tool (headless loses it) |

---

## Invocation skeleton

```bash
claude -p "your prompt here" \
  --output-format json \
  --session-id "$(uuidgen)" \
  --permission-mode default \
  --allowedTools "Read,Grep,Glob" \
  --model claude-sonnet-4-6 \
  --max-budget-usd 0.25
```

**Read before executing**: `./05-safe-defaults.md` for permission-preserving flag combinations and forbidden patterns.

---

## Core flags (reference)

### Session identity & continuity

| Flag | Purpose |
|---|---|
| `--session-id <uuid>` | Pin a UUID so hive bookkeeping can reference the child. Always pass one for traceability. |
| `-r, --resume [id]` | Resume a prior session by ID or name (from `/rename`). Opens picker if omitted. |
| `-c, --continue` | Continue most recent session in the current directory. |
| `--fork-session` | When resuming, fork to a new session ID instead of mutating the original. Use to branch a line of enquiry without losing the trunk. |
| `--from-pr [value]` | Resume a session linked to a PR by number/URL. |

### Input / output

| Flag | Purpose |
|---|---|
| `-p, --print` | Headless mode. Mandatory for non-interactive runs. |
| `--output-format {text,json,stream-json}` | `text` for humans, `json` for one-shot structured output, `stream-json` for live tool/message frames. |
| `--input-format {text,stream-json}` | Use `stream-json` for realtime streaming input (only with `--print`). |
| `--include-partial-messages` | Emits message chunks as they arrive. Stream-json + print only. |
| `--include-hook-events` | Include all hook-lifecycle events in the output stream. Stream-json only. |
| `--replay-user-messages` | Re-emit user messages from stdin so a supervisor can ack them. |
| `--json-schema <schema>` | Validate structured output against a JSON Schema. |

### Permissions & tools

| Flag | Purpose |
|---|---|
| `--permission-mode {default,acceptEdits,auto,bypassPermissions,dontAsk,plan}` | Set the child's permission mode. See `./05-safe-defaults.md` for forbidden combos. |
| `--allowedTools "Read Grep Bash(git *)"` | Restrict the child to this tool list (space- or comma-separated). |
| `--disallowedTools "Edit Write"` | Blocklist specific tools. |
| `--tools <names>` | Alternative: set the complete built-in tool roster. `""` disables all. `default` enables all. |
| `--dangerously-skip-permissions` | **Forbidden from sub-agents.** See `./05-safe-defaults.md`. |
| `--allow-dangerously-skip-permissions` | Enables the above flag as an *option*; do not pass from sub-agents. |

### Prompts, settings, MCP, agents

| Flag | Purpose |
|---|---|
| `--system-prompt <text>` | Override the default system prompt entirely. |
| `--append-system-prompt <text>` | Add to the default system prompt. Safer than `--system-prompt`. |
| `--settings <file-or-json>` | Load additional settings (file path or inline JSON). |
| `--setting-sources user,project,local` | Restrict which setting scopes are loaded. |
| `--mcp-config <files…>` | Load MCP servers from JSON files or strings. |
| `--strict-mcp-config` | Ignore all other MCP configs. |
| `--agents '<json>'` | Inject custom agent definitions inline. |
| `--agent <name>` | Use a specific agent for the run. |
| `--plugin-dir <path>` | Load plugins from a directory for this session only (repeatable). |

### Execution control

| Flag | Purpose |
|---|---|
| `--model <alias-or-id>` | Pin the model (`sonnet`, `opus`, `haiku`, or full ID like `claude-sonnet-4-6`). |
| `--effort {low,medium,high,xhigh,max}` | Reasoning budget. `xhigh` and `max` require Opus 4.7. |
| `--fallback-model <id>` | Auto-fall-back on overload (print mode only). |
| `--max-budget-usd <amount>` | Cap spend. Print mode only. Use for any unattended run. |
| `--add-dir <paths…>` | Additional directories the child can touch. |
| `--bare` | Minimal mode: skip hooks, LSP, plugin sync, CLAUDE.md auto-discovery, memory, etc. Use only when you know the child does not need those. |
| `--brief` | Enable `SendUserMessage` tool for agent-to-user comms. |
| `--no-session-persistence` | Session is not saved to disk. Print mode only. |
| `-w, --worktree [name]` | Create a fresh git worktree for the run. |

### Telemetry & debugging

| Flag | Purpose |
|---|---|
| `--debug [filter]` | Debug mode with optional category filter. |
| `--debug-file <path>` | Write debug logs to a specific file. |
| `--betas <betas…>` | Beta headers (API-key users only). |

Environment: `TRACEPARENT` / `TRACESTATE` from the parent are honoured for distributed tracing (CLI 2.1.110+).

---

## Output envelopes

### `--output-format json` (one-shot)

```json
{
  "session_id": "…",
  "result": "…final text…",
  "num_turns": 3,
  "cost_usd": 0.08,
  "exit_code": 0,
  "plugin_errors": [ … ]
}
```

`plugin_errors` appears when plugins were demoted for unsatisfied dependencies (CLI 2.1.111+).

### `--output-format stream-json`

Emits one JSON object per line:

1. `init` frame — includes `session_id`, settings summary, `plugin_errors` if any.
2. Many `assistant` / `tool_use` / `tool_result` / `user` frames interleaved.
3. `result` frame — terminal, includes `cost_usd`, `num_turns`, `exit_code`.

Stream consumers must be tolerant of unknown frame types (forward compatibility).

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Completed successfully |
| 1 | Generic error (check stderr) |
| 2 | Bad CLI args or validation failure |
| 124 | Timed out |
| 130 | User interrupted (SIGINT) |

Non-zero from a headless child should be logged as a `FAILED` event in the parent's hive (see `./06-recipes.md`).

---

## Session continuity recipes (summary)

Full recipes in `./06-recipes.md`. In one line each:

- **Forked probe**: `claude -p "…" --fork-session --session-id $NEW --resume $PARENT` — branch an enquiry from the parent's state.
- **Pure fresh**: `claude -p "…" --session-id $(uuidgen) --no-session-persistence --bare --allowedTools Read` — no persistence, no hooks, read-only. Smallest blast radius.
- **Cross-repo probe**: `claude -p "…" --add-dir /path/to/other-repo --allowedTools Read,Grep,Glob` — read-only cross-project exploration.

---

## Before you run — checklist

1. Did you pick a `--session-id`? (Use `uuidgen`.)
2. Did you bound `--allowedTools` to the minimum the child needs?
3. Did you set `--permission-mode` — and is it **not** `bypassPermissions` or `dangerouslySkipPermissions`?
4. Did you set `--max-budget-usd` for unattended runs?
5. Did you choose `--output-format json` (parseable) or `text` (human)? Don't mix.
6. Will you emit a manual SPAWN event in the parent? (See `./06-recipes.md` §4. The `hive-subagent-start.sh` hook does **not** fire for `claude -p`.)
7. Did you pass `depth` in the prompt if spawning from an agent context?

If any answer is "no", fix before running.
