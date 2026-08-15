#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
HOME_DIR="$REPO_DIR/.home"

echo "=== Claude Docker — omc Profile Setup ==="
echo ""

# OS detection
OS="linux"
if [[ "$(uname -s)" == "Darwin" ]]; then
    OS="macos"
elif grep -qi microsoft /proc/version 2>/dev/null; then
    OS="wsl"
fi
echo "Detected OS: $OS"

# Docker GID
DOCKER_GID=""
case "$OS" in
    linux|wsl)
        DOCKER_GID=$(getent group docker | cut -d: -f3 2>/dev/null || echo "984")
        echo "Docker GID: $DOCKER_GID"
        ;;
    macos)
        echo "macOS: Docker Desktop handles socket permissions — no GID needed."
        ;;
esac
echo ""

# Auth mode
read -rp "Default auth mode [sso/apikey] (default: sso): " AUTH_MODE
AUTH_MODE="${AUTH_MODE:-sso}"

# Base URL
echo "ANTHROPIC_BASE_URL:"
echo "  1) api.anthropic.com (default)"
echo "  2) https://api.fuelix.ai"
echo "  3) Other / skip"
read -rp "  Choice [1]: " BASE_URL_CHOICE
case "${BASE_URL_CHOICE:-1}" in
    1) BASE_URL="https://api.anthropic.com" ;;
    2) BASE_URL="https://api.fuelix.ai" ;;
    3) read -rp "  Enter URL (press Enter to leave blank): " BASE_URL ;;
    *) BASE_URL="https://api.anthropic.com" ;;
esac

# API key (silent)
API_KEY=""
if [[ -n "$BASE_URL" ]]; then
    read -rsp "ANTHROPIC_API_KEY (press Enter to skip): " API_KEY
    echo ""
fi

# SSH directory
read -rp "SSH key directory [~/.ssh] (press Enter to use default, 'skip' to skip mount): " SSH_INPUT
if [[ "${SSH_INPUT,,}" == "skip" ]]; then
    SSH_DIR=""
else
    SSH_DIR="${SSH_INPUT:-$HOME/.ssh}"
fi

# Workspace directory
read -rp "Default workspace directory (press Enter to leave unset — uses \$PWD at runtime): " WORKDIR_INPUT

# Write .env
cat > "$ENV_FILE" <<EOF
# Auth
DEFAULT_AUTH=${AUTH_MODE}
ANTHROPIC_API_KEY=${API_KEY}
ANTHROPIC_BASE_URL=${BASE_URL}

# Mounts
SSH_DIR=${SSH_DIR}
CLAUDE_WORKDIR=${WORKDIR_INPUT}
EOF
echo ""
echo ".env written to $ENV_FILE"

# Build image
echo ""
echo "Building claude-code:omc image..."
export DOCKER_GID
docker compose -f "$PROFILE_DIR/docker-compose.yml" build
echo "Build complete."

# Seed .home/
echo ""
echo "Seeding .home/.claude/..."
mkdir -p "$HOME_DIR/.claude"

cat > "$HOME_DIR/.claude/settings.json" <<'SETTINGS'
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "permissions": {
    "allow": []
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

# Done
echo ""
echo "=========================================="
echo "Setup complete!"
echo ""
echo "Add this alias to ~/.bash_aliases:"
echo ""
echo "  alias claude-sandbox='$REPO_DIR/claude.sh'"
echo ""
echo "Then run: source ~/.bash_aliases"
echo ""
echo "First-run notes:"
if [[ "$AUTH_MODE" == "sso" ]]; then
    echo "  - SSO: Look for a URL in the terminal — open it in your host browser"
fi
echo "  - Approve the TELUS managed settings dialog — happens once per profile"
echo "=========================================="
