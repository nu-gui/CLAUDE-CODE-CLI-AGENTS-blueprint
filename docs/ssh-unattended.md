# SSH Agent Strategy for Unattended Nightly Git Operations

**Machine:** `${USER}-workstation` (Ubuntu 24.04, user `${USER}`)
**Key file:** `~/.ssh/id_ed25519_github`
**Issue:** [PUFFIN-S3 #69](https://github.com/${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint/issues/69)

---

## Current State

Detection result (run `scripts/check-ssh-state.sh` to reproduce):

```bash
if ssh-keygen -y -P "" -f ~/.ssh/id_ed25519_github >/dev/null 2>&1; then
  echo "KEY_STATE: no-passphrase"
else
  echo "KEY_STATE: has-passphrase"
fi
```

**Result: `KEY_STATE: no-passphrase`**

`~/.ssh/id_ed25519_github` has **no passphrase**. The automation path does not need an SSH agent daemon — the key loads directly on demand by `git` / `gh` via the OpenSSH client.

---

## Recommended Strategy: Option A — Passphrase-less Key

Because the key has no passphrase, unattended `git push` and `gh` operations succeed in any non-interactive shell, including cron-fired sessions with no TTY. No `ssh-agent` service, no keychain, no extra setup required.

### Why this works

OpenSSH (`ssh`, `git@github.com`, `gh` via SSH protocol) reads the key file at `~/.ssh/id_ed25519_github` directly when the `IdentityFile` stanza is set in `~/.ssh/config`. Because there is no passphrase, the client never prompts for one.

### Security mitigations (important)

A passphrase-less private key means **any process running as `${USER}` can use it**. Apply these mitigations:

| Control | Command / Action |
|---------|-----------------|
| Restrictive file permissions | `chmod 600 ~/.ssh/id_ed25519_github` (verify with `ls -la ~/.ssh/`) |
| Confirm key registered only on GitHub | `gh ssh-key list` — remove any stale entries |
| Consider per-automation deploy key | See Option C below — a dedicated key scoped to automation repos limits blast radius if the machine is compromised |
| Monitor GitHub audit log | <https://github.com/settings/security-log> — watch for unexpected pushes from `${USER}-workstation` |
| Full-disk encryption | Ensure `/home/${USER}` sits on an encrypted volume (Ubuntu installer default) so physical theft doesn't expose the key |

---

## Implementation Steps

No action required beyond verifying permissions:

```bash
# 1. Confirm permissions
ls -la ~/.ssh/id_ed25519_github
# Expected: -rw------- 1 ${USER} ${USER} ...

# 2. Fix if wrong
chmod 600 ~/.ssh/id_ed25519_github

# 3. Confirm ~/.ssh/config routes github.com to this key
grep -A3 'github.com' ~/.ssh/config
# Should include: IdentityFile ~/.ssh/id_ed25519_github
```

---

## Verification Procedure

Run this in a fresh non-interactive shell (mimicking cron context):

```bash
# Simulates cron's non-interactive environment
timeout 10s ssh -o BatchMode=yes -T git@github.com 2>&1
# Expected exit code: 1  (GitHub returns exit 1 but prints "Hi <user>!")
# Failure modes:
#   exit 124  => 10s timeout (key missing or agent not running)
#   exit 255  => auth failed (key not registered with GitHub)
```

A successful check prints:
```
Hi ${GITHUB_ORG:-your-org}! You've successfully authenticated, but GitHub does not provide shell access.
```

The `nightly-dispatch.sh` preflight (added in this PR) runs this check automatically before any git-push stage and sets `SSH_PUSH_DISABLED=1` on failure so the pipeline never hangs.

---

## Rollback Steps

If the passphrase-less key is ever replaced with a passphrased key (e.g., after a security rotation):

1. Follow **Option B** (systemd user ssh-agent) or **Option C** (dedicated automation key) below.
2. Update `~/.ssh/config` to point automation at the new key.
3. Re-run the verification procedure above.
4. Notify the nightly-puffin pipeline — no code change needed; the preflight check will surface failures automatically via `BLOCKED: ssh-preflight-fail` in `events.ndjson`.

---

## Alternatives Considered

### Option B — systemd user `ssh-agent` (for passphrased keys)

Use this if the key ever gains a passphrase (e.g., compliance mandate).

**How it works:**

1. A `systemd --user` service starts `ssh-agent` at login and exports `SSH_AUTH_SOCK`.
2. `ssh-add` must be run **once interactively after boot** to unlock the passphrased key into the agent.
3. `loginctl enable-linger ${USER}` makes the user service survive after the user logs out (required for cron).
4. `SSH_AUTH_SOCK` is exported via `~/.config/environment.d/ssh-agent.conf` so all login shells pick it up.

**Unit file** (`~/.config/systemd/user/ssh-agent.service`):

```ini
[Unit]
Description=SSH key agent
Before=default.target

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a $SSH_AUTH_SOCK
Restart=on-failure

[Install]
WantedBy=default.target
```

**Environment export** (`~/.config/environment.d/ssh-agent.conf`):

```
SSH_AUTH_SOCK="${XDG_RUNTIME_DIR}/ssh-agent.socket"
```

**Enable:**

```bash
loginctl enable-linger ${USER}
systemctl --user enable --now ssh-agent.service
# Then once interactively after each reboot:
ssh-add ~/.ssh/id_ed25519_github
```

**Tradeoff:** The key is passphrase-protected at rest but must be manually unlocked after each reboot. If the machine reboots overnight, the pipeline blocks until a human runs `ssh-add`. Not suitable for fully unattended operation across reboots without a secure keychain daemon (e.g., `gnome-keyring` or `kwallet`, which add complexity).

---

### Option C — Dedicated passphrase-less automation deploy key

Generate a second key used **only** by nightly-puffin automation. Register it as a GitHub user SSH key (or a per-repo deploy key for tighter scope).

**Steps (user performs these; do not run unattended):**

```bash
# Generate — no passphrase
ssh-keygen -t ed25519 -C "nightly-puffin@${USER}-workstation" -f ~/.ssh/id_ed25519_nightly -N ""

# Register with GitHub
gh ssh-key add ~/.ssh/id_ed25519_nightly.pub --title "nightly-puffin ${USER}-workstation"

# Add a Host alias in ~/.ssh/config
cat >> ~/.ssh/config <<'EOF'

Host github-nightly
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_nightly
  IdentitiesOnly yes
EOF

# Update remote URL in repos that nightly-puffin pushes to:
# git remote set-url origin git@github-nightly:${GITHUB_ORG:-your-org}/<repo>.git
```

**Rotation policy:**

- Rotate annually or immediately on any suspected compromise.
- After rotation: `gh ssh-key delete <old-id>`, re-run `ssh-keygen` + `gh ssh-key add`.
- The preflight check in `nightly-dispatch.sh` will surface a `BLOCKED: ssh-preflight-fail` event on the first failed night, alerting you before morning digest.

**Tradeoff vs Option A:** Tighter blast radius (automation key can't push to repos it wasn't granted). Extra operational burden (key rotation, remote-URL management across repos). Recommended if the machine is shared or if `id_ed25519_github` is also used for interactive access you want to keep isolated.
