# Disaster Recovery Guide

**Pipeline**: nightly-puffin + daytime-harrier
**Repo**: ${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint (this repo lives at `~/.claude`)
**TL;DR**: See `README_RESTORE.md` at the repo root.

---

## Prerequisites

Two secrets are **unrecoverable from the repo** — you must have them before starting:

| Secret | Where it lives | How to restore |
|--------|----------------|----------------|
| SSH private key | `~/.ssh/id_ed25519_github` | Restore from your encrypted backup (1Password / Bitwarden). This key authorises `git@github.com` clones. |
| Claude workspace login | claude.ai browser session | Re-authenticate at https://claude.ai and then run `claude auth login`. There is no token file to back up. |

Everything else (scripts, configs, timer units) is reproduced by the bootstrap script.

---

## One-Command Recovery

Once the SSH key is in place:

```bash
# 1. Place your SSH key first
install -m 600 /path/to/backup/id_ed25519_github ~/.ssh/id_ed25519_github

# 2. Run the bootstrap
bash <(ssh git@github.com cat ${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint/scripts/bootstrap-fresh-machine.sh)
```

Or if you have the repo cloned already:

```bash
bash ~/.claude/scripts/bootstrap-fresh-machine.sh
```

The script is idempotent — safe to re-run on a partially-installed machine.

---

## Step-by-Step

### Step 1: Place the SSH key

```bash
install -m 600 /path/to/backup/id_ed25519_github ~/.ssh/id_ed25519_github
# Verify GitHub access
ssh -T git@github.com -i ~/.ssh/id_ed25519_github
# Expected output contains: "successfully authenticated"
```

### Step 2: Install Node (if not present)

```bash
# nvm (recommended — matches the rest of the project fleet)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc
nvm install 22 && nvm use 22
```

### Step 3: Run the bootstrap script

```bash
bash ~/.claude/scripts/bootstrap-fresh-machine.sh
```

What the script does, in order:

| # | Action | Idempotency |
|---|--------|-------------|
| 1 | `sudo loginctl enable-linger $USER` | Skipped if already enabled |
| 2 | Create `~/github/${GITHUB_ORG:-your-org}/` and `~/github/${GITHUB_ORG:-your-org}/` | Skipped if dirs exist |
| 3 | `git clone git@github.com:${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint ~/.claude` | Skipped if `~/.claude/.git` exists |
| 4 | `npm install -g @anthropic-ai/claude-code@<cli_pin>` (pin from `config/nightly-schedule.yaml`) | Skipped if version already matches |
| 5 | Interactive `claude auth login` pause | Skipped if already authenticated |
| 6 | `bash ~/.claude/scripts/install-systemd-timers.sh` (26+ timers) | Timer installer is itself idempotent |

### Step 4: Manual post-install steps

These cannot be automated (they require a browser session):

1. **Reconnect MCPs** — Navigate to `claude.ai/settings/connectors` and re-authorise each connector (Gmail, Google Calendar, Figma, etc.).

2. **Re-register PATs** (optional but recommended) — See `docs/pat-posture.md` for the scope split and rotation runbook. Export the new PAT as `GITHUB_TOKEN` in your shell or `~/.claude/config/.env`.

---

## Verification Procedure

Run these in order after the bootstrap completes:

```bash
# 1. Confirm systemd timers are live
systemctl --user list-timers 'nightly-puffin-*.timer'
# Expected: 26+ active timers

# 2. Check linger is enabled
loginctl show-user "$USER" | grep Linger
# Expected: Linger=yes

# 3. Smoke-test the selector script
bash ~/.claude/scripts/nightly-select-projects.sh --dry-run

# 4. Smoke-test the dispatcher
bash ~/.claude/scripts/nightly-dispatch.sh stage=A --dry-run

# 5. Confirm CLI version matches pin
claude --version
# Should match cli_pin in config/nightly-schedule.yaml (currently 2.1.111)

# 6. Confirm GitHub CLI auth
gh auth status
# Should show: Logged in to github.com as ${GITHUB_ORG:-your-org}
```

---

## Rollback

If the bootstrap leaves the machine in a bad state, the recovery path is:

```bash
# Remove installed units without touching the repo
bash ~/.claude/scripts/install-systemd-timers.sh --uninstall

# Remove partial clone (only if you have the SSH key and can re-clone)
rm -rf ~/.claude
bash <clone-command>   # see Step-by-Step above

# Revert to a prior CLI version
npm install -g @anthropic-ai/claude-code@<prior-pin>
```

No data is lost by rollback — the repo is the source of truth and is not modified by the bootstrap script (except for the initial clone).

---

## Flags Reference

| Flag | Effect |
|------|--------|
| `--skip-clone` | Skip step 3 (git clone). Use when `~/.claude/.git` already exists. |
| `--skip-install` | Skip step 6 (systemd timer install). |
| `--dry-run` | Print every action without executing mutations. Safe to run at any time. |

---

## Secrets Reference

| Secret | Backup location | Can be regenerated? |
|--------|----------------|---------------------|
| `~/.ssh/id_ed25519_github` | Encrypted password manager | No — revoke old key and add new public key on GitHub if lost |
| Claude workspace login | N/A (browser OAuth) | Yes — re-authenticate at claude.ai |
| `GITHUB_TOKEN` (PAT) | Encrypted password manager | Yes — revoke and re-create at github.com/settings/tokens |

---

## References

- Bootstrap script: `scripts/bootstrap-fresh-machine.sh`
- Timer installer: `scripts/install-systemd-timers.sh`
- Schedule (cli_pin lives here): `config/nightly-schedule.yaml`
- PAT posture and rotation: `docs/pat-posture.md`
- SSH unattended setup: `docs/ssh-unattended.md`
- Systemd timer pivot design: `docs/systemd-timer-pivot.md`
