#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
HOME_DIR="$REPO_DIR/.home"

echo "=== Claude Docker — omc Profile Setup ==="
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

# oh-my-claudecode's own `omc setup` (run below) writes settings.json's
# hooks/statusLine and merges around whatever keys already exist here —
# it does not need enabledPlugins/extraKnownMarketplaces (that machinery is
# for the marketplace-install path; this profile installs the npm CLI instead).
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

HOST_CLAUDE_MD="$HOME/.claude/CLAUDE.md"
if [[ -f "$HOST_CLAUDE_MD" ]]; then
    cp "$HOST_CLAUDE_MD" "$HOME_DIR/.claude/CLAUDE.md"
    echo "  CLAUDE.md copied from $HOST_CLAUDE_MD"
else
    echo "  Warning: $HOST_CLAUDE_MD not found — skipping CLAUDE.md seed."
fi

echo "  Running omc setup (installs hooks/agents/skills, merges settings.json/CLAUDE.md)..."
docker run --rm --entrypoint omc \
    -v "$HOME_DIR:/home/${CONTAINER_USER}" \
    -e "HOME=/home/${CONTAINER_USER}" \
    -u "${CONTAINER_UID}:${CONTAINER_GID}" \
    claude-code:omc setup --quiet
echo "  omc setup complete."
