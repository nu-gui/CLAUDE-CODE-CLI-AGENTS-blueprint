#!/usr/bin/env python3
"""
gmail_draft.py — create a Gmail draft via the Gmail API.

Replaces the `claude -p` + Gmail-MCP path in morning-digest.sh (which no
longer works: MCP connectors are interactive-session-only, not available
in cron-spawned `claude -p` subprocesses — confirmed 2026-04-24).

## One-time setup (operator)

1. Go to https://console.cloud.google.com/apis/credentials for your Google
   account (the one that should own the draft — e.g. your-email@example.com).
2. Create (or select) a project; enable the Gmail API.
3. Create an OAuth 2.0 Client ID of type "Desktop app".
4. Download the JSON → save as:
     ~/.config/morning-digest-gmail/credentials.json
5. Run:
     python3 -m pip install --user google-auth google-auth-oauthlib google-api-python-client
     python3 ~/.claude/scripts/lib/gmail_draft.py --setup
   The --setup flow opens a browser, asks you to grant
   https://www.googleapis.com/auth/gmail.modify scope, and writes
     ~/.config/morning-digest-gmail/token.json
   From then on, token.json auto-refreshes and no interactive input is
   needed.

## Usage from cron

  python3 ~/.claude/scripts/lib/gmail_draft.py \\
    --to "your-email@example.com" \\
    --subject "Nightly digest 2026-04-24" \\
    --body-file ${HOME}/.claude/context/hive/digests/2026-04-24.md

On success prints ONE line:
  gmail_draft_id=<id> subject=<subject-encoded>
Exit 0.

On failure prints ONE line:
  gmail_draft_id=FAILED reason=<short>
Exit non-zero.

No external runtime dependencies beyond google-auth / google-auth-oauthlib /
google-api-python-client (pip-installed once during setup).
"""

import argparse
import base64
import json
import os
import sys
from email.mime.text import MIMEText
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("GMAIL_DRAFT_CONFIG_DIR",
                                  Path.home() / ".config" / "morning-digest-gmail"))
CREDS_FILE = CONFIG_DIR / "credentials.json"
TOKEN_FILE = CONFIG_DIR / "token.json"

# Minimal scope: drafts only (we never send, never read user mail).
# modify is needed to CREATE a draft even though we don't send — send +
# insert + modify are the write scopes; drafts.create is under modify.
SCOPES = ["https://www.googleapis.com/auth/gmail.modify"]


def _fail(reason: str, exit_code: int = 1) -> None:
    print(f"gmail_draft_id=FAILED reason={reason}")
    sys.exit(exit_code)


def _import_google_libs():
    """Import Google API libs lazily so a --setup hint can still print
    before the import error if the pip install hasn't happened yet."""
    try:
        from google.auth.transport.requests import Request
        from google.oauth2.credentials import Credentials
        from google_auth_oauthlib.flow import InstalledAppFlow
        from googleapiclient.discovery import build
        from googleapiclient.errors import HttpError
    except ImportError as e:
        _fail(
            f"missing-google-libs ({e.name}). Run: "
            "python3 -m pip install --user google-auth google-auth-oauthlib google-api-python-client",
            exit_code=2,
        )
    return Request, Credentials, InstalledAppFlow, build, HttpError


def _load_creds():
    """Load + refresh credentials, or print actionable error on first-use."""
    Request, Credentials, InstalledAppFlow, build, HttpError = _import_google_libs()

    if not CREDS_FILE.exists():
        _fail(
            f"missing-credentials.json at {CREDS_FILE} — download OAuth Desktop client JSON "
            "from Google Cloud Console; see gmail_draft.py docstring for setup",
            exit_code=3,
        )

    creds = None
    if TOKEN_FILE.exists():
        try:
            creds = Credentials.from_authorized_user_file(str(TOKEN_FILE), SCOPES)
        except Exception as e:
            _fail(f"token-read-failed {e}", exit_code=4)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            try:
                creds.refresh(Request())
            except Exception as e:
                _fail(f"refresh-failed {e}; delete {TOKEN_FILE} and re-run --setup", exit_code=5)
            TOKEN_FILE.write_text(creds.to_json())
        else:
            _fail(
                f"no-valid-token — run: python3 {Path(__file__).resolve()} --setup",
                exit_code=6,
            )

    return creds, build, HttpError


def _setup_interactive():
    """One-time interactive OAuth flow — opens a browser."""
    Request, Credentials, InstalledAppFlow, build, HttpError = _import_google_libs()

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if not CREDS_FILE.exists():
        print(f"ERROR: {CREDS_FILE} not found.", file=sys.stderr)
        print(
            "Download an OAuth 2.0 Client ID (type 'Desktop app') from "
            "https://console.cloud.google.com/apis/credentials and save it as the path above.",
            file=sys.stderr,
        )
        sys.exit(3)

    # Ensure permissions are tight
    try:
        os.chmod(CREDS_FILE, 0o600)
    except Exception:
        pass

    flow = InstalledAppFlow.from_client_secrets_file(str(CREDS_FILE), SCOPES)
    creds = flow.run_local_server(port=0)

    TOKEN_FILE.write_text(creds.to_json())
    try:
        os.chmod(TOKEN_FILE, 0o600)
    except Exception:
        pass

    print(f"Setup OK. Token saved to {TOKEN_FILE}")
    print("Now test with:")
    print(
        f"  python3 {Path(__file__).resolve()} --to you@example.com "
        '--subject "test" --body-file /etc/hostname'
    )


def _create_draft(creds, build, HttpError, to_addr: str, subject: str, body: str) -> str:
    """Create a Gmail draft; returns the draft id."""
    service = build("gmail", "v1", credentials=creds)
    message = MIMEText(body, _charset="utf-8")
    message["to"] = to_addr
    message["subject"] = subject
    raw = base64.urlsafe_b64encode(message.as_bytes()).decode("utf-8")

    try:
        draft = (
            service.users()
            .drafts()
            .create(userId="me", body={"message": {"raw": raw}})
            .execute()
        )
    except HttpError as e:
        _fail(f"gmail-api-error {e.status_code} {e.reason}", exit_code=7)
    except Exception as e:
        _fail(f"gmail-api-unknown {e}", exit_code=8)

    return draft.get("id", "")


def main() -> None:
    parser = argparse.ArgumentParser(description="Create a Gmail draft via the Gmail API.")
    parser.add_argument("--setup", action="store_true", help="Run one-time interactive OAuth setup.")
    parser.add_argument("--to", help="Recipient email address.")
    parser.add_argument("--subject", help="Draft subject line.")
    parser.add_argument(
        "--body-file",
        help="Path to a file whose contents become the draft body (plain text).",
    )
    args = parser.parse_args()

    if args.setup:
        _setup_interactive()
        return

    if not (args.to and args.subject and args.body_file):
        _fail("missing-args — need --to, --subject, --body-file (or --setup)", exit_code=1)

    body_path = Path(args.body_file)
    if not body_path.is_file():
        _fail(f"body-file-not-found {body_path}", exit_code=1)
    body = body_path.read_text(encoding="utf-8", errors="replace")

    creds, build, HttpError = _load_creds()
    draft_id = _create_draft(creds, build, HttpError, args.to, args.subject, body)

    # Single-line sentinel that morning-digest.sh greps for. Keep the
    # shape aligned with the old claude -p sentinel format for digest
    # event-log continuity.
    subject_safe = args.subject.replace("\n", " ").replace("\r", " ")
    print(f"gmail_draft_id={draft_id} subject={subject_safe[:200]}")


if __name__ == "__main__":
    main()
