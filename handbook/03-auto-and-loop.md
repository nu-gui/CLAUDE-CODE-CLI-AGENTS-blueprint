# 03 — Auto Mode & `/loop`

> How to behave when the session is running unattended and how to pace your own polling.
> **Most important rule**: the prompt cache has a 5-minute TTL. Sleep windows that straddle 300 s pay the worst price — a cache miss without the benefit of a long wait.

---

## Auto mode (summary)

Auto mode is the harness telling you: *make reasonable assumptions, decide, execute, don't interrupt for routine decisions*.

- From CLI 2.1.111, no `--enable-auto-mode` flag is required.
- You will see a system reminder `## Auto Mode Active` at session start when it's on.

### Contract under auto mode

- Execute immediately on low-risk work. Make reasonable assumptions.
- Prefer action over planning. Do **not** enter plan mode unless the user explicitly asks.
- Minimise interruptions. For routine decisions (which skill, which tool, which flag) decide yourself — see `./07-decision-guide.md`.
- **Destructive actions still require explicit confirmation.** Auto mode is not a license to `rm -rf`, drop tables, force-push to `main`, post to Slack/email, or delete branches without asking.
- **No data exfiltration.** Do not post to chat platforms, tickets, or external services unless the user explicitly directed it. Never share secrets.

### What NOT to do under auto mode

- Do not ask "should I proceed?" before every file change.
- Do not write planning documents unless asked.
- Do not run `AskUserQuestion` for tool selection.
- Do not loosen permissions with `--dangerously-skip-permissions`, ever.

---

## `/loop` — self-pacing and interval-paced

Two flavours:

### Dynamic / self-paced — `/loop <prompt>`

No interval given. You are in charge of pacing. Every turn, you must decide:

- Do I have more work to do? If yes, schedule the next wake via `ScheduleWakeup`.
- Do I need to stop? Omit the `ScheduleWakeup` call.

Runtime recognises the sentinel `<<autonomous-loop-dynamic>>` in the `prompt` field of `ScheduleWakeup` and re-injects the original /loop prompt at wake time.

### Interval-paced — `/loop 5m <prompt>` / `/loop 30m <prompt>`

A fixed cadence. The harness re-fires on its own. You do not call `ScheduleWakeup`. You do not call `CronCreate`.

### Autonomous loop (no user /loop, CronCreate-driven)

For long-running autonomous work scheduled via `CronCreate`, use the sentinel `<<autonomous-loop>>` in the cron job's prompt. Do **not** confuse it with `<<autonomous-loop-dynamic>>` — the two map to different runtime paths.

---

## Cache-TTL pacing (the 300 s rule)

Prompt cache lives for 5 minutes (300 s), optionally extended to 1 hour via `ENABLE_PROMPT_CACHING_1H`. Cache hits are ~10× cheaper and faster; misses reload the full conversation.

| Sleep window | Cache state | When to use |
|---|---|---|
| 60 s – 270 s | Stays warm | Active work: polling a short build, waiting for state that's about to change, checking a process you just started. |
| **≈ 300 s (240–360 s)** | **Worst case — cache miss + short wait** | **Never pick this.** |
| 1200 s – 3600 s | One cache miss, amortised over a long wait | Idle ticks, no urgent signal, or genuinely long-running external state. |

**Defaults for idle polling**: 1200 s – 1800 s (20–30 min). `ScheduleWakeup` clamps `delaySeconds` to `[60, 3600]` — you don't need to clamp yourself.

### Picking `delaySeconds` — decision rules

| What you're waiting for | Choose |
|---|---|
| Build that takes ~2 min | 90 – 120 s |
| Build that takes ~10 min | 270 s × 3 iterations (stays in cache the first two) |
| User response to a PR comment | 1200 s floor |
| Cron-style "check hourly" | `CronCreate` at `0 * * * *`, not `ScheduleWakeup` |
| "Every Monday morning" | `CronCreate` at `0 9 * * 1` |
| "Tick every ~10 min for the next hour" | `ScheduleWakeup` with 300–600 s delays… **NO**: use 270 s so you stay cached. |

---

## `ScheduleWakeup` vs `CronCreate`

| Aspect | `ScheduleWakeup` | `CronCreate` |
|---|---|---|
| Lifetime | One-shot per call | Recurring until `CronDelete` |
| Pacing | Dynamic — you choose each wake | Fixed cron expression |
| Context | Same session continues | New session each fire |
| Sentinel | `<<autonomous-loop-dynamic>>` | `<<autonomous-loop>>` |
| Best for | /loop without interval; polling a changing process | Recurring tasks across days/weeks |
| Cost risk | Low if you pick windows well | Medium (each fire may reload context) |

Do not stack: if you have a `CronCreate` trigger active, don't also `ScheduleWakeup` inside each fire unless you genuinely need intra-fire polling.

---

## Loop-safe state

Never truncate state between iterations. Treat the loop as potentially crash-recovered at every turn.

- Write per-iteration artefacts under `~/.claude/context/hive/sessions/<SESSION_ID>/loops/<loop-id>/<UTC-ts>.md` (file-per-iteration, append-only).
- Read the most recent 3–5 iterations on wake to reconstruct state.
- Do not rely on in-memory variables across `ScheduleWakeup` calls — the runtime may evict context between fires.
- Emit a `PROGRESS` event per iteration with a `detail:"loop-iter-N"` marker so hive observers can see you're alive.

---

## Interacting with the user during a loop

- If you need user input to continue, emit a `BLOCKED` event with `reason:"awaiting-user-input"`, stop scheduling, and return. Do not continuously ping `AskUserQuestion` across iterations.
- If the loop produces a material change (build fixed, PR merged, incident resolved), emit a `COMPLETE` event and stop — don't keep polling a resolved state.
- If the user wants status, they can interrupt; the harness handles that. You do not need to pre-emptively announce every tick.

---

## `/schedule` (the skill)

The `schedule` skill is the user-facing path to `CronCreate` / `CronList` / `CronDelete` / `RemoteTrigger`. You can invoke it via `Skill(schedule)` if the task really is "set up a recurring remote job." For in-session pacing, prefer `ScheduleWakeup` directly.

---

## Common mistakes

- **Picking 300 s because "5 minutes feels right"** — you pay the cache-miss without earning the longer wait. Drop to 270 s or jump to 1200 s.
- **Sleeping in a Bash loop** — the harness blocks leading long sleeps and you're burning context. Use `Monitor` or `ScheduleWakeup`.
- **Polling for something that will page someone** — don't self-restart a loop across a user-signalled stop. Respect `BLOCKED` and `COMPLETE` states.
- **Forgetting to pass the sentinel** — if `ScheduleWakeup.prompt` doesn't carry `<<autonomous-loop-dynamic>>` (or the original /loop input), the loop won't resume correctly.
- **Mixing `CronCreate` and `ScheduleWakeup` unnecessarily** — pick one lifecycle and stick to it.
