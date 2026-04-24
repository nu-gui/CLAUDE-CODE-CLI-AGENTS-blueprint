#!/usr/bin/env bash
# bootstrap-fresh-machine.sh
#
# One-command disaster-recovery bootstrap for nightly-puffin + daytime-harrier.
# Idempotent — re-running on a half-installed machine converges to the same
# end-state as a fresh install.
#
# Prerequisites (human must supply BEFORE running):
#   1. ~/.ssh/id_ed25519_github — private key for git@github.com clone access
#      (chmod 600 and loaded into ssh-agent if passphrase-protected)
#   2. The calling user must have sudo privileges (needed for loginctl step only)
#
# Usage:
#   bash bootstrap-fresh-machine.sh [--skip-clone] [--skip-install] [--dry-run]
#
# Flags:
#   --skip-clone    Skip git clone (step 3) — use when ~/.claude/.git already exists
#   --skip-install  Skip systemd timer install (step 6)
#   --dry-run       Print what would be done without executing any mutations
#
# After this script completes:
#   - Reconnect MCPs at claude.ai/settings/connectors
#   - (Optional) Re-register fine-grained PATs per docs/pat-posture.md
#   - Verify: systemctl --user list-timers 'nightly-puffin-*.timer'

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
REPO_SSH="git@github.com:${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint.git"
CLAUDE_DIR="$HOME/.claude"
SCHEDULE_YAML="$CLAUDE_DIR/config/nightly-schedule.yaml"
GITHUB_BASE="$HOME/github"
GITHUB_NU_GUI="$GITHUB_BASE/${GITHUB_ORG:-your-org}"
GITHUB_NU_GUI_CSS="$GITHUB_BASE/${GITHUB_ORG:-your-org}"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
SKIP_CLONE=0
SKIP_INSTALL=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --skip-clone)   SKIP_CLONE=1 ;;
    --skip-install) SKIP_INSTALL=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    *)
      echo "ERROR: Unknown flag: $arg" >&2
      echo "Usage: $0 [--skip-clone] [--skip-install] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
step()  { echo ""; echo "=== $* ==="; }

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

run_sudo() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] sudo $*"
  else
    sudo "$@"
  fi
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
step "Pre-flight checks"

if [[ "$DRY_RUN" -eq 1 ]]; then
  warn "DRY-RUN mode — no mutations will be applied"
fi

# SSH key must exist (even in dry-run, the key is needed for real clone)
if [[ ! -f "$HOME/.ssh/id_ed25519_github" ]]; then
  die "~/.ssh/id_ed25519_github not found. Place the private key before running."
fi
info "SSH key present: $HOME/.ssh/id_ed25519_github"

# SSH agent / key reachability check
SSH_TEST=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
               -i "$HOME/.ssh/id_ed25519_github" \
               git@github.com 2>&1 || true)
if echo "$SSH_TEST" | grep -q "successfully authenticated"; then
  info "GitHub SSH auth: OK"
elif [[ "$DRY_RUN" -eq 1 ]]; then
  warn "GitHub SSH auth check skipped in dry-run mode"
else
  die "GitHub SSH auth failed. Ensure the key is correct and has repo access. Output: $SSH_TEST"
fi

# ---------------------------------------------------------------------------
# Step 1: Enable systemd user linger
# ---------------------------------------------------------------------------
step "Step 1: Enable systemd user linger (loginctl enable-linger)"

if loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
  info "Linger already enabled for $USER — skipping"
else
  run_sudo loginctl enable-linger "$USER"
  info "Linger enabled for $USER"
fi

# ---------------------------------------------------------------------------
# Step 2: Ensure ~/github/ base directories
# ---------------------------------------------------------------------------
step "Step 2: Ensure ~/github/ base directories"

for dir in "$GITHUB_BASE" "$GITHUB_NU_GUI" "$GITHUB_NU_GUI_CSS"; do
  if [[ -d "$dir" ]]; then
    info "Directory exists: $dir"
  else
    run mkdir -p "$dir"
    info "Created: $dir"
  fi
done

# ---------------------------------------------------------------------------
# Step 3: Clone ~/.claude from GitHub (idempotent)
# ---------------------------------------------------------------------------
step "Step 3: Clone CLAUDE-CODE-CLI-AGENTS into ~/.claude"

if [[ "$SKIP_CLONE" -eq 1 ]]; then
  info "--skip-clone set, skipping git clone"
elif [[ -d "$CLAUDE_DIR/.git" ]]; then
  info "~/.claude/.git already exists — clone skipped (use 'git -C ~/.claude pull' to update)"
elif [[ -e "$CLAUDE_DIR" ]]; then
  die "~/.claude exists but is NOT a git repo. Remove or move it before proceeding."
else
  run git clone "$REPO_SSH" "$CLAUDE_DIR"
  info "Cloned into $CLAUDE_DIR"
fi

# ---------------------------------------------------------------------------
# Step 4: Install pinned claude CLI
# ---------------------------------------------------------------------------
step "Step 4: Install pinned @anthropic-ai/claude-code from nightly-schedule.yaml"

# Read cli_pin from YAML (simple grep — avoids requiring yq on a fresh machine)
if [[ ! -f "$SCHEDULE_YAML" ]]; then
  if [[ "$SKIP_CLONE" -eq 1 ]] || [[ "$DRY_RUN" -eq 1 ]]; then
    CLI_PIN="2.1.111"  # hardcoded fallback for dry-run / skip-clone paths
    warn "Schedule YAML not found; using fallback CLI_PIN=$CLI_PIN"
  else
    die "$SCHEDULE_YAML not found after clone. Check repo structure."
  fi
else
  CLI_PIN=$(grep -E '^\s*cli_pin:' "$SCHEDULE_YAML" | head -1 | sed 's/.*cli_pin:[[:space:]]*//' | tr -d '"' | tr -d "'")
  if [[ -z "$CLI_PIN" ]]; then
    die "Could not parse cli_pin from $SCHEDULE_YAML"
  fi
  info "Pinned CLI version: $CLI_PIN"
fi

INSTALLED_PIN=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [[ "$INSTALLED_PIN" == "$CLI_PIN" ]]; then
  info "claude CLI $CLI_PIN already installed — skipping npm install"
else
  info "Installing @anthropic-ai/claude-code@$CLI_PIN (currently: ${INSTALLED_PIN:-not installed})"
  run npm install -g "@anthropic-ai/claude-code@$CLI_PIN"
fi

# ---------------------------------------------------------------------------
# Step 5: Interactive claude auth login
# ---------------------------------------------------------------------------
step "Step 5: Authenticate Claude CLI (claude auth login)"

if claude auth status &>/dev/null; then
  info "Claude CLI already authenticated — skipping interactive login"
else
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] Would run: claude auth login"
    echo "[DRY-RUN] (interactive pause for browser auth)"
  else
    echo ""
    echo "ACTION REQUIRED: You must authenticate the Claude CLI."
    echo "A browser window will open (or a URL will be printed). Complete the login,"
    echo "then return here and press ENTER to continue."
    echo ""
    claude auth login || die "claude auth login failed. Re-run after fixing auth."
    echo ""
    read -r -p "Press ENTER once you have completed authentication in the browser..."
    echo ""
    info "Auth step complete"
  fi
fi

# ---------------------------------------------------------------------------
# Step 6: Install systemd timers
# ---------------------------------------------------------------------------
step "Step 6: Install systemd user timers (install-systemd-timers.sh)"

INSTALL_TIMERS_SCRIPT="$CLAUDE_DIR/scripts/install-systemd-timers.sh"

if [[ "$SKIP_INSTALL" -eq 1 ]]; then
  info "--skip-install set, skipping systemd timer installation"
elif [[ ! -f "$INSTALL_TIMERS_SCRIPT" ]]; then
  die "$INSTALL_TIMERS_SCRIPT not found. Ensure step 3 completed successfully."
else
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] Would run: bash $INSTALL_TIMERS_SCRIPT --dry-run"
    bash "$INSTALL_TIMERS_SCRIPT" --dry-run 2>&1 | sed 's/^/  [timer-installer] /'
  else
    run bash "$INSTALL_TIMERS_SCRIPT"
    info "Systemd timers installed"
  fi
fi

# ---------------------------------------------------------------------------
# Post-install hints
# ---------------------------------------------------------------------------
step "Bootstrap complete — post-install checklist"

cat <<'HINTS'

  Bootstrap finished successfully. Complete these manual steps:

  1. RECONNECT MCPs
     Navigate to: claude.ai/settings/connectors
     Re-authorise each MCP connector (Gmail, Google Calendar, Figma, etc.)
     MCPs are tied to the Claude workspace session and cannot be automated.

  2. RE-REGISTER FINE-GRAINED PATs (optional but recommended)
     See: ~/.claude/docs/pat-posture.md
     Target scopes:
       puffin-claude-config-pat  — write access to CLAUDE-CODE-CLI-AGENTS only
       puffin-cross-repo-read-pat — read-only across all repos
     Set in shell: export GITHUB_TOKEN=<new-pat>
     Or in .env / systemd unit EnvironmentFile.

  3. VERIFY TIMERS
     systemctl --user list-timers 'nightly-puffin-*.timer'
     Expected: 26+ timers listed (one per trigger in nightly-schedule.yaml)

  4. SMOKE TEST
     bash ~/.claude/scripts/nightly-select-projects.sh --dry-run
     bash ~/.claude/scripts/nightly-dispatch.sh stage=A --dry-run

HINTS

info "Recovery complete for user: $USER"
