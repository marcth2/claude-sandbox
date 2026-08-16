#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
HOME_DIR="$REPO_DIR/.home"

echo "=== Claude Docker — vanilla Profile Setup ==="
echo ""

# shellcheck source=profiles/_common.sh
source "$REPO_DIR/profiles/_common.sh"

common_detect_os
common_prompt_auth
common_prompt_mounts
common_prompt_git
common_prompt_mcp
common_write_env
common_build_image
common_seed_home
common_seed_gh_skill
common_register_mcp

cat >"$HOME_DIR/.claude/settings.json" <<'SETTINGS'
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "skipDangerousModePermissionPrompt": true,
  "skipWorkflowUsageWarning": true,
  "alwaysThinkingEnabled": true,
  "spinnerTipsEnabled": true,
  "theme": "dark"
}
SETTINGS
echo "  settings.json written."
