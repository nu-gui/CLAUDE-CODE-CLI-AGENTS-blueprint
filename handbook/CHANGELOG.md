# Handbook CHANGELOG

Tracks handbook revisions + the CLI version each revision was validated against.

| Handbook ver | Date | CLI pin | Notes |
|---|---|---|---|
| 1.0.0 | 2026-04-16 | 2.1.111 | Initial release. Eight files. Preamble slim-refactor in parallel. |

---

## CLI feature drift (watch-list)

Items the handbook must stay in sync with as the CLI evolves. Each entry: upstream change, where handbook content depends on it.

| CLI ver | Change | Handbook dependency |
|---|---|---|
| 2.1.111 | `xhigh` effort level added for Opus 4.7; `/effort` opens slider when argless | 01-cli-headless.md `--effort` values |
| 2.1.111 | Auto mode no longer requires `--enable-auto-mode` | 03-auto-and-loop.md invocation |
| 2.1.111 | `/less-permission-prompts` skill added | 02-in-session-toolbelt.md skill list |
| 2.1.111 | `/ultrareview` skill added | 02-in-session-toolbelt.md + 07-decision-guide.md security review branch |
| 2.1.111 | `plugin_errors` on `--output-format stream-json` init event | 01-cli-headless.md envelope |
| 2.1.110 | `PushNotification` tool added; `--resume`/`--continue` resurrects scheduled tasks | 02-in-session-toolbelt.md |
| 2.1.110 | `TRACEPARENT`/`TRACESTATE` honoured in headless | 01-cli-headless.md |
| 2.1.108 | Built-in slash commands (`/init`, `/review`, `/security-review`) invocable via Skill tool | 02-in-session-toolbelt.md |
| 2.1.108 | `ENABLE_PROMPT_CACHING_1H` / `FORCE_PROMPT_CACHING_5M` env vars | 03-auto-and-loop.md cache-TTL rules |
| 2.1.105 | `/proactive` aliased to `/loop`; `PreCompact` hook can block | 03-auto-and-loop.md |
| 2.1.92 | `/vim` removed (use `/config` → Editor mode) | Do not reference `/vim` |
| 2.1.91 | `/pr-comments` removed | Do not reference `/pr-comments` |

---

## Skill & tool removals / renames — do not reference

- `/vim` — removed 2.1.92. Use `/config` → Editor mode.
- `/pr-comments` — removed 2.1.91.
- `/review` — deprecated; install `code-review` plugin instead.
- `--enable-auto-mode` — no longer required 2.1.111.

---

## How to bump

1. Land handbook edits.
2. Append a row to the version table above.
3. If a new CLI version invalidates a recipe in `06-recipes.md`, mark the recipe as `⚠ stale (CLI X.Y.Z)` and fix.
4. If preamble stub in `~/.claude/agents/_HIVE_PREAMBLE_v3.8.md` changes contract, bump handbook major version (2.0.0, …).
