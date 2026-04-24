# 05 — Safe Defaults (Permissions & Forbidden Patterns)

> Before invoking `claude -p` or calling an MCP tool that mutates external state, read this file.
> **Rule of thumb**: the child session must never have more authority than the user's current permission posture.

---

## Forbidden flag combinations (sub-agent → `claude -p` child)

| Flag or combination | Why forbidden | Alternative |
|---|---|---|
| `--dangerously-skip-permissions` from a sub-agent | Bypasses every permission prompt + `permissions.deny` rule. Undermines the user's consent. Only a human at the interactive CLI may enable this. | Request the specific tool via `--allowedTools` and let the user approve once. |
| `--allow-dangerously-skip-permissions` without a matching explicit allow-list | Surfaces the dangerous flag as an option the child could toggle. | Omit. Let the child rely on `--permission-mode default`. |
| `--permission-mode bypassPermissions` | Identical effect to skip-permissions at runtime. | `default` or `acceptEdits`. |
| `--bare` + wildcard `--allowedTools default` | Removes hooks, memory, CLAUDE.md discovery while granting all tools — the child loses every guardrail. | If you use `--bare`, restrict `--allowedTools` to the narrowest set (usually `Read,Grep,Glob`). |
| `--tools ""` + expecting Bash | Disables all tools including Bash; the child cannot act. | List tools explicitly. |
| `--strict-mcp-config` with no `--mcp-config` | Blocks all MCP including user's configured servers; intended only for deliberately MCP-less runs. | Pass `--mcp-config` with the file(s) you actually need. |
| Hard-coded full path to `~/.claude/settings.local.json` in `--settings` | May leak personal tokens if the child writes its output to a PR or log. | Prefer `--setting-sources user,project` and avoid `local`. |
| `--permission-mode plan` + `--output-format text` + unattended | Plan mode expects an interactive approval; text mode in a pipe hangs or returns no mutations silently. | Use `--output-format stream-json` to observe the plan request, or drop to `default`. |

---

## Safe combinations (copy-paste-ready)

### Read-only probe (smallest blast radius)

```bash
claude -p "$PROMPT" \
  --output-format json \
  --session-id "$(uuidgen)" \
  --permission-mode default \
  --allowedTools "Read,Grep,Glob" \
  --max-budget-usd 0.25 \
  --no-session-persistence \
  --bare
```

Use for independent lookups that do not need hive integration.

### Hive-integrated sibling (child participates in session events)

```bash
claude -p "SESSION_ID: $SESSION_ID\nPROJECT_KEY: $PROJECT_KEY\ndepth 1/2\n\n$PROMPT" \
  --output-format json \
  --session-id "$(uuidgen)" \
  --permission-mode default \
  --allowedTools "Read,Grep,Glob,Bash(git log *),Bash(git diff *)" \
  --max-budget-usd 0.50 \
  --setting-sources user,project
```

The child reads and writes the same hive. Emit a manual SPAWN event in the parent — see `./06-recipes.md` §4.

### Cross-repo read (different codebase)

```bash
claude -p "$PROMPT" \
  --output-format json \
  --session-id "$(uuidgen)" \
  --permission-mode default \
  --allowedTools "Read,Grep,Glob" \
  --add-dir "/path/to/other-repo" \
  --no-session-persistence \
  --bare \
  --max-budget-usd 0.25
```

### Mutating child (branch, commit, push) — only when explicitly authorised

```bash
claude -p "$PROMPT" \
  --output-format stream-json \
  --session-id "$(uuidgen)" \
  --permission-mode default \
  --allowedTools "Read,Grep,Glob,Edit,Write,Bash(git *),Bash(gh *)" \
  --disallowedTools "Bash(rm *),Bash(git push --force *)" \
  --setting-sources user,project \
  --max-budget-usd 1.50 \
  --include-hook-events
```

`--include-hook-events` is important here so the parent can observe permission prompts as they happen.

---

## Permission-mode cheat-sheet

| Mode | Agent behaviour | Use in `claude -p` child? |
|---|---|---|
| `default` | Prompts for risky tools per settings. | YES — the normal choice. |
| `acceptEdits` | Auto-accepts file edits; still prompts for shell, etc. | YES, but prefer `default` unless you want silent edits. |
| `auto` | Auto-mode classifier decides (see `./03-auto-and-loop.md`). | YES for genuinely low-risk, bounded work. |
| `plan` | Plan-only; mutations require explicit approval. | YES for analysis/design runs — but pair with a supervisor. |
| `dontAsk` | Never prompts; denies by `permissions.deny`. | YES for unattended runs against known-safe tools. |
| `bypassPermissions` | **Forbidden** from sub-agent-spawned children. | NO. |

---

## Pre-flight checklist for `claude -p`

Before hitting enter:

- [ ] `--session-id` pinned (from `uuidgen`), **not** reused from the parent unless explicitly resuming/forking.
- [ ] `--allowedTools` set to the minimum needed. Do not `--tools default`.
- [ ] `--permission-mode` is **not** `bypassPermissions`.
- [ ] `--max-budget-usd` set for any run that may exceed ~30 seconds.
- [ ] `--output-format` matches how the parent will parse the output.
- [ ] If `--bare` is set, tools are narrowed below the wildcard default.
- [ ] `--setting-sources` excludes `local` if the child's output may be shared externally.
- [ ] If the child will write files, parent has a strategy to consume them (branch, PR, or explicit checkpoint).
- [ ] Parent will emit a SPAWN event manually (`hive-subagent-start.sh` does not fire for `claude -p`).
- [ ] `depth` in the prompt is `≤ M` from the recursion limit.

If any box is unchecked, fix before running.

---

## Credentials and secrets

- Never pass secrets via `--append-system-prompt`. They persist in session transcripts.
- Prefer `--settings` with a file path to a settings JSON that references env vars by name, not inline values.
- If a child must authenticate (e.g. GitHub), pass `GH_TOKEN` via the parent's environment; the child inherits env. Do not re-export secrets in the prompt.
- MCP calls that touch Gmail, Calendar, or external APIs can exfiltrate data. Verify user authorisation for both the action and the destination.

---

## Reference patterns

- `~/.claude/context/shared/patterns/PATTERN-VH-003_claude_cli_ssh_wrapper.md` — SSH-wrapper allowlist + audit-log approach for `claude -p` over SSH.
- `~/.claude/context/shared/decisions/DEC-VH-002_ssh_execution_model.md` — decision record for the SSH execution model using `claude -p --output-format json`.

Both are existing, battle-tested patterns for mutating `claude -p` runs. When in doubt, adapt them rather than inventing new patterns.
