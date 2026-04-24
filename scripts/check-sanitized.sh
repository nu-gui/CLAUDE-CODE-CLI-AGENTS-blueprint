#!/bin/bash
#
# check-sanitized.sh
# USAGE_START
# Sanitization check — fails if any upstream-specific identifier is found
# in the blueprint's tracked files.
#
# Run locally:       bash scripts/check-sanitized.sh
# Run via CI:        see .github/workflows/sanitization-check.yml
#
# Purpose: the public blueprint at nu-gui/CLAUDE-CODE-CLI-AGENTS-blueprint
# must stay generic so anyone can fork it. This script is the gate that
# catches accidental re-introductions of the original maintainer's
# personal identifiers, infrastructure, or project-specific names.
#
# For FORKS: once you customize this blueprint for your own environment
# (populate .env, add your repos to config/*, etc.), you will likely
# introduce values this script considers "leaks" — because your fork is
# supposed to carry YOUR identifiers. Two options:
#
#   1. Disable the check: add `if: false` to the sanitization-check job in
#      .github/workflows/sanitization-check.yml, or delete that workflow.
#   2. Edit the LEAK_PATTERNS array below: remove upstream-specific
#      patterns (they'll never match your fork anyway), add patterns for
#      the upstream maintainer of YOUR fork's upstream (e.g. strings from
#      this blueprint) so you catch drift if you later sync from upstream.
#
# Exit codes:
#   0 — no leak patterns matched
#   1 — one or more patterns matched (PR / push will fail in CI)
#   2 — grep invocation error
# USAGE_END
#

set -eo pipefail

# Patterns that MUST NOT appear in tracked files on the upstream blueprint.
# Forks customise this list; upstream keeps it exhaustive.
#
# Each entry is an extended-regex fed to `grep -E`. Lines starting with `#`
# are grouping comments for readability.
LEAK_PATTERNS=(
  # ─── Personal identity (upstream maintainer) ───────────────────────────
  'wesleyburgess'
  '\bwesley\b'
  '\bwes@'
  'zyongate'

  # ─── Hostnames / machines ──────────────────────────────────────────────
  'burg-optiplex'
  '\b-optiplex\b'

  # ─── Prod IP octets (upstream's VPS fleet — seen nowhere else) ────────
  # Final octet is 1–3 digits so we catch the full 0–255 range, not just
  # single-digit hosts. Trailing \b prevents spurious matches on
  # 102.223.1234 or 102.223.19.extra.
  '\b102\.223\.[0-9]{1,3}\b'
  '\b102\.211\.[0-9]{1,3}\b'
  '\b102\.207\.[0-9]{1,3}\b'
  '\b102\.209\.[0-9]{1,3}\b'
  '\b192\.168\.10\.[0-9]{1,3}\b'

  # ─── Upstream-owned repo names ─────────────────────────────────────────
  '\bWSNextGenCCS-AI\b'
  '\bwsnextgenccs\b'
  '\bnu-trade_'
  '\bccs-cdr-[a-z]'
  '\bCCS-SIP-Server-source-code\b'
  '\bCCS-Whisper-Transcription-Languages\b'

  # ─── Org label (upstream maintainer's legal entity) ────────────────────
  'NU GUI \(Pty\) Ltd'

  # ─── Sprint / project identifiers (upstream project management) ───────
  '\bPUFFIN-W[0-9]+-ID[0-9]'
  '\bW1[0-9]-ID[0-9]'
)

# Dirs and files exempt from the scan. The script itself contains the
# patterns by definition, so it must not match itself. `.git/` contains
# committer info (real names/emails) that matches \bwes@ etc. by design.
EXEMPT_DIRS=(
  '.git'
)
EXEMPT_FILES=(
  'check-sanitized.sh'
)

EXCLUDE_DIR_FLAGS=()
EXCLUDE_FILE_FLAGS=()
for d in "${EXEMPT_DIRS[@]}"; do
  EXCLUDE_DIR_FLAGS+=("--exclude-dir=$d")
done
for f in "${EXEMPT_FILES[@]}"; do
  EXCLUDE_FILE_FLAGS+=("--exclude=$f")
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

show_help() {
  sed -n '/^# USAGE_START$/,/^# USAGE_END$/{//!p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  --help|-h) show_help; exit 0 ;;
esac

echo "=== blueprint sanitization check ==="

any_leak=0
match_count=0

for pattern in "${LEAK_PATTERNS[@]}"; do
  # `grep -I` skips binary files; `-P` = Perl-compatible regex (PCRE)
  # so `\b` reliably means word boundary and `{n,m}` means repetition.
  # In POSIX ERE mode (`-E`), `\b` is ambiguous across grep implementations
  # (GNU grep treats it as word boundary, strict POSIX treats it as a
  # backspace). `-P` makes the semantics unambiguous. Requires a GNU grep
  # built with PCRE support, which is the default on every mainstream
  # Linux distribution. On macOS, install via `brew install grep` and
  # invoke as `ggrep` — or disable this workflow on non-Linux forks.
  matches="$(grep -rPIn "$pattern" . \
    "${EXCLUDE_DIR_FLAGS[@]}" "${EXCLUDE_FILE_FLAGS[@]}" 2>/dev/null || true)"

  if [[ -n "$matches" ]]; then
    echo ""
    echo -e "${RED}✗${NC} leak pattern: ${YELLOW}$pattern${NC}"
    # Show up to 5 matches with file:line
    echo "$matches" | head -5 | sed 's/^/    /'
    extra=$(echo "$matches" | wc -l | tr -d ' ')
    if [[ "$extra" -gt 5 ]]; then
      echo "    (+ $((extra - 5)) more)"
    fi
    match_count=$((match_count + extra))
    any_leak=1
  fi
done

echo ""

if [[ $any_leak -eq 0 ]]; then
  echo -e "${GREEN}✓${NC} all patterns clean — blueprint stays fork-ready"
  exit 0
fi

echo -e "${RED}✗${NC} $match_count leak line(s) found across $(echo "${LEAK_PATTERNS[@]}" | wc -w) tracked patterns"
echo ""
echo "If you've forked this blueprint and intentionally added content that"
echo "matches a pattern above, edit LEAK_PATTERNS in this script to suit"
echo "your fork — or disable .github/workflows/sanitization-check.yml."
exit 1
