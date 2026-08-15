#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
HOME_DIR="$REPO_DIR/.home"

echo "=== Claude Docker — omc Profile Setup ==="
echo ""

# shellcheck source=../_common.sh
source "$REPO_DIR/profiles/_common.sh"

common_detect_os
common_prompt_auth
common_prompt_mounts
common_write_env
common_build_image
common_seed_home

cat > "$HOME_DIR/.claude/settings.json" <<'SETTINGS'
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "skipDangerousModePermissionPrompt": true,
  "skipWorkflowUsageWarning": true,
  "alwaysThinkingEnabled": true,
  "spinnerTipsEnabled": true,
  "theme": "dark",
  "enabledPlugins": {
    "oh-my-claudecode@omc": true
  },
  "extraKnownMarketplaces": {
    "omc": {
      "source": {
        "source": "git",
        "url": "https://github.com/Yeachan-Heo/oh-my-claudecode.git"
      }
    }
  },
  "statusLine": {
    "type": "command",
    "command": "node ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud/omc-hud.mjs"
  }
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

echo "  Seeding .omc-config.json..."
OMC_VERSION=$(docker run --rm --entrypoint node claude-code:omc \
    -e "console.log(require('/usr/local/lib/node_modules/oh-my-claudecode/package.json').version)" \
    2>/dev/null || echo "unknown")
SETUP_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$HOME_DIR/.claude/.omc-config.json" <<EOF
{
  "defaultExecutionMode": "ultrawork",
  "configuredAt": "$SETUP_TIMESTAMP",
  "team": {
    "ops": {
      "maxAgents": 3,
      "defaultAgentType": "claude",
      "monitorIntervalMs": 30000,
      "shutdownTimeoutMs": 15000
    }
  },
  "setupCompleted": "$SETUP_TIMESTAMP",
  "setupVersion": "$OMC_VERSION"
}
EOF
echo "  .omc-config.json written (omc $OMC_VERSION)."
