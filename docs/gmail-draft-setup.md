# Gmail-draft channel setup (morning-digest.sh)

The nightly morning digest delivers to 4 channels:

1. Local markdown at `~/.claude/context/hive/digests/YYYY-MM-DD.md`
2. **Gmail draft** — the subject of this doc
3. GitHub Discussion
4. example-repo memory file append

This doc covers the one-time operator setup for (2).

## Background

The Gmail channel previously used `claude -p` + the claude.ai Gmail MCP connector. As of 2026-04-24 that path is broken: Claude Code MCP connectors are strictly interactive-session-scoped, and a cron-spawned `claude -p` subprocess cannot reach them. Confirmed by the claude-code-guide docs agent citing the official headless-mode documentation.

Replacement: `scripts/lib/gmail_draft.py` calls the Gmail REST API directly via `google-api-python-client`, backed by an OAuth refresh token stored locally at `~/.config/morning-digest-gmail/token.json`. Once set up, it refreshes itself and works unattended — no Claude session required.

## One-time setup

### 1. Create an OAuth 2.0 Client ID in Google Cloud Console

Do this as the **Google account that should own the drafts** — typically `your-email@example.com` (per `config/digest-config.yaml` `delivery.gmail_draft.recipient`). Log in to the Google Cloud Console as that user.

1. Go to <https://console.cloud.google.com/apis/credentials>
2. Create (or select) a project. Naming suggestion: `morning-digest-gmail`.
3. APIs & Services → Library → search "Gmail API" → **Enable**.
4. APIs & Services → Credentials → **Create Credentials** → **OAuth client ID**.
5. If prompted to configure the consent screen first:
   - User type: **Internal** (if your Google account is in a Workspace) or **External** (personal Gmail).
   - App name: `morning-digest-gmail`.
   - User support email: your own.
   - Save and continue through the scopes screen (leave empty — the runtime scope is `gmail.modify`, requested automatically at auth time).
   - Test users (External only): add your Google account as a test user.
6. Back at "Create OAuth client ID":
   - Application type: **Desktop app**
   - Name: `morning-digest-gmail`
   - **Create**
7. Click **Download JSON** on the new client row.

### 2. Place the JSON

```bash
mkdir -p ~/.config/morning-digest-gmail
mv ~/Downloads/client_secret_*.json ~/.config/morning-digest-gmail/credentials.json
chmod 600 ~/.config/morning-digest-gmail/credentials.json
```

### 3. Run the setup helper

```bash
bash ~/.claude/scripts/setup-gmail-draft-oauth.sh
```

The helper will:

1. Check `credentials.json` exists (else print the steps above again).
2. Create a dedicated venv at `~/.config/morning-digest-gmail/venv/` and `pip install` the google-auth libs inside it. (PEP 668 on Ubuntu 24.04+ blocks `pip install --user` system-wide; the venv isolates the libs from apt-managed Python.)
3. Run an interactive OAuth flow — a browser window opens; grant the `gmail.modify` scope.
4. Write the refresh token to `~/.config/morning-digest-gmail/token.json` (mode 600).
5. Create a smoke-test draft titled `gmail-draft setup smoke test` — check your Gmail Drafts folder, then delete it.

Prerequisite: `python3-venv` (apt-installed by default on Ubuntu). Check with `python3 -m venv --help`; install with `sudo apt install python3-venv` if missing.

### 4. Verify tomorrow

Tomorrow's 07:00 local time `nightly-digest-out` run will write a real draft. Check `~/.claude/context/hive/logs/morning-digest-gmail.log` after it fires:

- Success: last line reads `gmail_draft_id=<id> subject=Nightly digest 2026-XX-XX — N opened, M merged, K promotions`
- Failure: last line reads `gmail_draft_id=FAILED reason=<short>` — the reason names the problem (missing credentials, refresh failed, API error, etc.)

`events.ndjson` carries the same information under `agent=digest event=PROGRESS`.

## Troubleshooting

| Error reason | Fix |
|---|---|
| `missing-credentials.json` | Step 2 above — drop the JSON at `~/.config/morning-digest-gmail/credentials.json` |
| `no-valid-token` | Step 3 above — run `setup-gmail-draft-oauth.sh` |
| `refresh-failed` | Token revoked (e.g. you changed Google password). Delete `token.json` and rerun `setup-gmail-draft-oauth.sh`. |
| `missing-google-libs` | Re-run `bash ~/.claude/scripts/setup-gmail-draft-oauth.sh` — it recreates the venv + reinstalls. |
| `gmail-api-error 403` | The OAuth client doesn't have Gmail scope. Re-run the setup helper; grant `gmail.modify` when the browser prompts. |

## Rotating credentials

If the OAuth client secret is compromised:

1. Delete it in the Google Cloud Console (APIs & Services → Credentials).
2. Delete the local `credentials.json` + `token.json`.
3. Re-run the setup from step 1.

## Why not service account?

Service accounts can only access Gmail mailboxes they have explicit domain-wide delegation for, which requires Workspace admin grants. User-OAuth via Desktop client is appropriate here: the script impersonates the operator's own account, which is the same account that'd normally compose the draft by hand.

## Files touched by this change

- `scripts/lib/gmail_draft.py` — new; Gmail API caller
- `scripts/setup-gmail-draft-oauth.sh` — new; one-time setup helper
- `scripts/morning-digest.sh` — Channel 2 now calls the Python script instead of `claude -p`
- `docs/gmail-draft-setup.md` — this file

No other scripts affected.
