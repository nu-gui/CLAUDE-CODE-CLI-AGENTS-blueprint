#!/bin/bash
# =============================================================================
# Example Post-Deploy Hook
# =============================================================================
# This hook runs after a successful deployment of Claude Code CLI Agents.
#
# Available context variables (exported by deploy script):
#   DEPLOY_CONFIG_DIR      - Path to deployed config (e.g., ~/.claude)
#   DEPLOY_BRANCH          - Git branch that was deployed
#   DEPLOY_TIMESTAMP       - ISO 8601 timestamp of deployment
#   DEPLOY_BACKUP_DIR      - Path to backup (empty if --no-backup)
#   DEPLOY_SCRIPT_VERSION  - Version of deploy script
#   DEPLOY_OS              - Operating system (linux, macos, unknown)
#   DEPLOY_DISTRO          - Linux distro ID (ubuntu, debian, etc.)
#   DEPLOY_USER            - User who ran the deployment
#
# Exit codes:
#   0 - Success (deployment continues)
#   1 - Failure (deployment fails if --strict-hooks is set)
#
# Hook timeout: Controlled by --hook-timeout (default: 60s)
# =============================================================================

set -euo pipefail

echo "Post-deploy hook running..."
echo "  Config: ${DEPLOY_CONFIG_DIR}"
echo "  Branch: ${DEPLOY_BRANCH}"
echo "  Time:   ${DEPLOY_TIMESTAMP}"
echo "  User:   ${DEPLOY_USER}"
echo "  OS:     ${DEPLOY_OS} (${DEPLOY_DISTRO})"

# Example: Verify critical files exist
if [ ! -f "${DEPLOY_CONFIG_DIR}/CLAUDE.md" ]; then
    echo "ERROR: CLAUDE.md not found!"
    exit 1
fi

# Example: Set custom permissions on sensitive files
# if [ -f "${DEPLOY_CONFIG_DIR}/settings.json" ]; then
#     chmod 600 "${DEPLOY_CONFIG_DIR}/settings.json"
#     echo "Set secure permissions on settings.json"
# fi

# Example: Initialize hive directories
mkdir -p "${DEPLOY_CONFIG_DIR}/context/hive/sessions"
echo "Ensured hive sessions directory exists"

# Example: Create local customization file if it doesn't exist
if [ ! -f "${DEPLOY_CONFIG_DIR}/local-overrides.yaml" ]; then
    cat > "${DEPLOY_CONFIG_DIR}/local-overrides.yaml" << 'EOF'
# Local Overrides
# Add VPS-specific customizations here
# This file is not overwritten by deployments

workflow:
  default_mode: direct
EOF
    echo "Created local-overrides.yaml"
fi

# Example: Send notification (uncomment to use)
# if command -v curl &> /dev/null; then
#     curl -s -X POST "https://hooks.example.com/deploy" \
#         -H "Content-Type: application/json" \
#         -d "{\"host\": \"$(hostname)\", \"branch\": \"${DEPLOY_BRANCH}\", \"time\": \"${DEPLOY_TIMESTAMP}\"}" \
#         || echo "Warning: Failed to send notification"
# fi

echo "Post-deploy hook completed successfully"
exit 0
