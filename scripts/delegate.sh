#!/usr/bin/env bash
# delegate.sh — hand a task off to ExternalAgent or ExternalAgent instead of
# spawning a Claude Code specialist in-session.
#
# Paired with the "Delegation Check" rules in ~/.claude/CLAUDE.md.
#
# Mechanism (hybrid, auto-picked):
#   1. POST to the ExternalAgent gateway at ${EXTERNAL_AGENT_GATEWAY_URL:-http://127.0.0.1:18789}
#      with Authorization: Bearer ${EXTERNAL_AGENT_GATEWAY_TOKEN}. Preferred — immediate.
#   2. Fall back to file drop at ~/.example-repo/inbound/<uuid>.json, polled by
#      ExternalAgent's watcher agent. Used when the gateway is unreachable.
#
# Usage:
#   delegate.sh --agent example-repo.sprint --task "Plan next sprint"
#   delegate.sh --agent example-repo.bridge --task "Email Operator a status update"
#   delegate.sh --agent example-repo.main   --task "Run the full e2e suite overnight" --priority high
#
# Flags:
#   --agent <agent-id>   Target (e.g. example-repo.sprint, example-repo.bridge)
#   --task <text>        Task description
#   --priority <level>   low | normal | high (default: normal)
#   --no-fallback        Fail if gateway unreachable (don't file-drop)
#   --dry-run            Print payload only; do not send
#   --help               Show this help

set -uo pipefail

AGENT=""
TASK=""
PRIORITY="normal"
ALLOW_FALLBACK=1
DRY_RUN=0

usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's|^# \{0,1\}||'; exit 0; }

while (( $# )); do
  case "$1" in
    --agent)        AGENT="$2"; shift 2 ;;
    --task)         TASK="$2";  shift 2 ;;
    --priority)     PRIORITY="$2"; shift 2 ;;
    --no-fallback)  ALLOW_FALLBACK=0; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --help|-h)      usage ;;
    *) echo "!! unknown flag: $1" >&2; usage ;;
  esac
done

[[ -n "${AGENT}" ]] || { echo "!! --agent required"; exit 2; }
[[ -n "${TASK}" ]]  || { echo "!! --task required";  exit 2; }
case "${PRIORITY}" in low|normal|high) ;; *) echo "!! --priority must be low|normal|high"; exit 2 ;; esac

# Resolve gateway target
GATEWAY_URL="${EXTERNAL_AGENT_GATEWAY_URL:-http://127.0.0.1:18789}"
GATEWAY_TOKEN="${EXTERNAL_AGENT_GATEWAY_TOKEN:-}"

# If token empty, try reading from ~/.example-repo/example-repo.json
if [[ -z "${GATEWAY_TOKEN}" ]] && [[ -f "${HOME}/.example-repo/example-repo.json" ]]; then
  GATEWAY_TOKEN=$(python3 -c "
import json, sys
try:
    with open('${HOME}/.example-repo/example-repo.json') as f:
        cfg = json.load(f)
    print(cfg.get('gateway', {}).get('auth', {}).get('token', ''))
except Exception:
    pass
" 2>/dev/null || true)
fi

REQUEST_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SOURCE_SESSION="${CLAUDE_SESSION_ID:-$(date +%s)}"

# Build payload. Values passed via env to avoid shell-quoting pitfalls
# (Python's os.environ handles arbitrary bytes, unlike f-string interpolation).
PAYLOAD=$(
  DELEGATE_AGENT="${AGENT}" \
  DELEGATE_TASK="${TASK}" \
  DELEGATE_PRIORITY="${PRIORITY}" \
  DELEGATE_REQUEST_ID="${REQUEST_ID}" \
  DELEGATE_TIMESTAMP="${TIMESTAMP}" \
  DELEGATE_SOURCE_SESSION="${SOURCE_SESSION}" \
  python3 -c "
import json, os
print(json.dumps({
  'tool': 'agent_invoke',
  'args': {
    'agent':    os.environ['DELEGATE_AGENT'],
    'task':     os.environ['DELEGATE_TASK'],
    'priority': os.environ['DELEGATE_PRIORITY'],
    'metadata': {
      'request_id':     os.environ['DELEGATE_REQUEST_ID'],
      'created_at':     os.environ['DELEGATE_TIMESTAMP'],
      'source_session': os.environ['DELEGATE_SOURCE_SESSION'],
      'source_platform':'claude-code-cli',
    }
  }
}))
" 2>/dev/null
)

if [[ -z "${PAYLOAD}" ]]; then
  echo "!! failed to build JSON payload (python3 required)" >&2
  exit 3
fi

if (( DRY_RUN )); then
  echo "==> would deliver:"
  echo "    request_id: ${REQUEST_ID}"
  echo "    agent:      ${AGENT}"
  echo "    priority:   ${PRIORITY}"
  echo "    gateway:    ${GATEWAY_URL}"
  echo "    token:      $( [[ -n "${GATEWAY_TOKEN}" ]] && echo "<set>" || echo "<missing>" )"
  echo "    payload:    ${PAYLOAD}"
  exit 0
fi

# Attempt Gateway API delivery
deliver_via_gateway() {
  if [[ -z "${GATEWAY_TOKEN}" ]]; then
    echo "[delegate] no gateway token — skipping gateway path" >&2
    return 1
  fi
  local code
  code=$(curl -s -o /tmp/delegate-resp.$$ -w '%{http_code}' --max-time 10 \
    -X POST "${GATEWAY_URL}/tools/invoke" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${GATEWAY_TOKEN}" \
    -d "${PAYLOAD}" 2>/dev/null || echo 000)
  if [[ "${code}" =~ ^2 ]]; then
    echo "[delegate] gateway ${code} ok  request_id=${REQUEST_ID}"
    rm -f /tmp/delegate-resp.$$
    return 0
  fi
  echo "[delegate] gateway ${code}" >&2
  [[ -s /tmp/delegate-resp.$$ ]] && head -c 300 /tmp/delegate-resp.$$ >&2
  rm -f /tmp/delegate-resp.$$
  return 1
}

# Attempt file-drop fallback. Atomic write: stage to .tmp on the same fs,
# then rename — guarantees the watcher never reads a partial file.
deliver_via_file() {
  local drop_dir="${HOME}/.example-repo/inbound"
  mkdir -p "${drop_dir}"
  local path="${drop_dir}/${REQUEST_ID}.json"
  local tmp="${drop_dir}/.${REQUEST_ID}.json.tmp"
  printf '%s\n' "${PAYLOAD}" > "${tmp}"
  mv -- "${tmp}" "${path}"
  echo "[delegate] file drop ok  path=${path}"
  echo "[delegate] NOTE: ExternalAgent watcher poll latency applies (5-30s)"
}

if deliver_via_gateway; then
  exit 0
fi

if (( ALLOW_FALLBACK )); then
  deliver_via_file
  exit 0
fi

echo "!! gateway delivery failed and --no-fallback was set" >&2
exit 4
