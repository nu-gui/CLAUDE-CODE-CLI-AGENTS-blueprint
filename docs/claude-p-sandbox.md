# `claude -p` Sandbox Runbook

> **Scope**: headless specialist execution inside nightly-puffin (Stages B1/B2).
> **Hive protocol reference**: `~/.claude/handbook/00-hive-protocol.md`
> **Related**: `docs/nightly-puffin.md`, PR #90, PR #108, PR #112

---

## 1. Mandatory invocation flags

```bash
claude -p "$PROMPT" \
  --permission-mode acceptEdits \
  --add-dir "$local_repo_path" \
  --add-dir "$HIVE" \
  --append-system-prompt "You are <agent-id> running headless. Execute directly — do not stop at a plan summary."
```

| Flag | What it does | What breaks without it |
|------|-------------|------------------------|
| `--permission-mode acceptEdits` | Auto-accepts Edit/Write tool proposals inside the subprocess | Tool calls queue for human approval that never arrives; subprocess stalls silently |
| `--add-dir <path>` | Grants the subprocess read/write access to that directory tree for Read/Edit/Write tools | Any path outside cwd is denied by the sandbox; silent write failures |
| `--append-system-prompt` | Injects headless execution context | Specialist stops at plan summary; no work done |

Repeat `--add-dir` once per directory. Always pass both the target repo path **and** `$HIVE`.

---

## 2. What `--add-dir` does NOT cover

`--add-dir` adds directories to the **tool allowlist** for Read/Edit/Write. It does **not** extend the Bash tool's shell environment.

Shell redirects in Bash tool calls bypass the allowlist entirely:

```bash
# This will be DENIED even with --add-dir $HIVE
echo '{"event":"SPAWN",...}' >> ~/.claude/context/hive/events.ndjson
```

The subprocess sees: `Error: path outside allowed directories` (or a silent denial depending on CLI version). This is upstream Claude CLI behavior — not a configuration error.

**Corollary**: a specialist cannot self-emit hive events via Bash redirect even if `--add-dir $HIVE` is present.

---

## 3. How nightly-puffin compensates

The dispatch wrapper (`nightly-dispatch.sh`) owns the lifecycle boundary. Specialists own the work.

### Lifecycle events (wrapper-side)

```
wrapper emits SPAWN
  └─► claude -p <specialist> runs
        └─► wrapper emits SPECIALIST_COMPLETE (exit 0)
            or SPECIALIST_FAILED     (exit ≠ 0)
```

Relevant PRs:
- **PR #90** — wrapper emits SPAWN before `claude -p` and SPECIALIST_COMPLETE/FAILED after
- **PR #108** — specialist prompts explicitly instruct "Do NOT write to events.ndjson directly"
- **PR #112** — heartbeat writes happen at wrapper level via `hive_heartbeat()`; specialists do not heartbeat themselves

### W18-ID13 credential-expiry detection

The wrapper reads specialist **stderr** at the wrapper level to detect auth failures (e.g. `gh: authentication required`). Specialists do not need to emit a BLOCKED event — the wrapper detects and emits it.

---

## 4. Specialist prompt contract

Every specialist prompt spawned via `claude -p` must include:

```
HEADLESS EXECUTION RULES:
- Do NOT emit hive events directly (no >> events.ndjson, no session folder writes)
- Do NOT create session folders under ~/.claude/context/hive/sessions/
- Do the work on disk: branch, edit, commit, push, PR
- Your exit code determines the wrapper's outcome:
    exit 0  → SPECIALIST_COMPLETE
    exit ≠ 0 → SPECIALIST_FAILED
- stdout is captured; include a one-line summary as your final stdout line
  (auto-included in the nightly digest)
```

### Minimal working example

```bash
HIVE="${HOME}/.claude/context/hive"
REPO_PATH="${HOME}/github/${GITHUB_ORG:-your-org}/my-repo"

PROMPT="SESSION_ID: ${SESSION_ID}
PROJECT_KEY: my-repo

TASK: Fix issue #42 — update the README.

HEADLESS EXECUTION RULES:
- Do NOT emit hive events directly
- Do NOT create session folders under ~/.claude/context/hive/sessions/
- Do the work on disk: branch, edit, commit, push, PR
- exit 0 on success, non-zero on failure
- Print one summary line to stdout before exiting
"

claude -p "$PROMPT" \
  --permission-mode acceptEdits \
  --add-dir "$REPO_PATH" \
  --add-dir "$HIVE" \
  --append-system-prompt "You are doc-00 running headless. Execute directly."
```

---

## 5. `settings.json` allowlist

Even with `--add-dir`, the Claude CLI may classify `.claude/` paths as sensitive by default. Add explicit allow entries in the repo-local `settings.json` (gitignored):

```json
{
  "allowedPaths": [
    "${HOME}/.claude/context/hive/**",
    "${HOME}/.claude/context/shared/**"
  ]
}
```

Without these, Write/Edit calls to hive paths may silently no-op regardless of `--add-dir`.

---

## 6. `hive-subagent-stop` hook caveat

The `hooks/hive-subagent-stop.sh` hook fires for **in-session `Agent()` tool spawns** in the parent process. It does **not** fire for headless `claude -p` children launched as subprocesses.

Do not rely on this hook to catch specialist lifecycle events from `claude -p` invocations. The wrapper script is the only reliable lifecycle boundary for headless specialists.

---

## 7. Troubleshooting

### Symptom: silent deny on `events.ndjson`

| | |
|--|--|
| **Symptom** | Specialist appears to succeed but no SPAWN/COMPLETE events appear in `events.ndjson`. No error in specialist stdout. |
| **Root cause** | Specialist attempted a shell redirect (`echo ... >> events.ndjson`) from inside the Bash tool. The redirect bypasses the `--add-dir` allowlist and is silently denied (or denied with a tool error the specialist ignored). |
| **Fix** | Remove all `>> events.ndjson` lines from the specialist prompt and specialist agent definition. The wrapper emits lifecycle events; the specialist should not. Verify with `tail -f ~/.claude/context/hive/events.ndjson` while running a test dispatch. |

---

### Symptom: looping retries on path-outside-allowed-dirs

| | |
|--|--|
| **Symptom** | Specialist loops, repeatedly retrying a Write or Edit call with variations of the same path. Exit 1 after timeout. Logs show `Error: path outside allowed directories`. This was the class of bug hit in W18-ID4 / issues #74 #75 #76. |
| **Root cause** | `--add-dir` was omitted for a path the specialist needs to write (e.g. a worktree path outside cwd, or the hive directory). The specialist sees the denial, retries with path variations, and eventually gives up. |
| **Fix** | Add the missing directory with `--add-dir <path>` in the wrapper invocation. Check the wrapper's `claude -p` call against the paths the specialist actually writes. Also confirm `settings.json` allowlist covers hive paths. |

---

### Symptom: false-positive `SPECIALIST_COMPLETE` with no actual PR

| | |
|--|--|
| **Symptom** | Wrapper emits `SPECIALIST_COMPLETE` (exit 0), but no commit or PR was created. Morning digest shows "1 PR" that does not exist. |
| **Root cause** | Specialist exited 0 after writing a plan summary without executing it. Either `--append-system-prompt` was missing (specialist paused at plan), or `--permission-mode acceptEdits` was absent (Edit/Write proposals never resolved, specialist returned "done" without mutations). |
| **Fix** | Confirm both `--permission-mode acceptEdits` and `--append-system-prompt "Execute directly — do not stop at a plan summary"` are present in the wrapper call. Add a post-run assertion in the wrapper: verify that at least one commit exists on the expected branch before emitting `SPECIALIST_COMPLETE`. |

---

## 8. Quick-reference checklist

Before any new headless spawn:

- [ ] `--permission-mode acceptEdits` present
- [ ] `--add-dir <repo_path>` present
- [ ] `--add-dir $HIVE` present (if specialist reads context files)
- [ ] `--append-system-prompt` present with "Execute directly" instruction
- [ ] Specialist prompt includes "Do NOT emit hive events directly"
- [ ] Specialist prompt includes "Do NOT create session folders"
- [ ] `settings.json` allowlist covers `.claude/context/hive/**` and `.claude/context/shared/**`
- [ ] Wrapper script asserts post-run artifacts (branch/commit/PR) before emitting COMPLETE

---

*Last updated: 2026-04-19 | Issue: PUFFIN-W18-ID11 | PR #102*
