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
read -rp "Default auth mode [sso/apikey] (default: apikey): " AUTH_MODE
AUTH_MODE="${AUTH_MODE:-apikey}"

# Base URL
echo "ANTHROPIC_BASE_URL:"
echo "  1) api.anthropic.com"
echo "  2) https://api.fuelix.ai (default)"
echo "  3) Other / skip"
read -rp "  Choice [2]: " BASE_URL_CHOICE
case "${BASE_URL_CHOICE:-2}" in
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

# Model selection (proxy/gateway mode only)
ANTHROPIC_MODEL=""
if [[ -n "$BASE_URL" && -n "$API_KEY" ]]; then
    echo "Fetching available Claude models from $BASE_URL..."
    CLAUDE_MODELS=()
    while IFS= read -r model; do
        [[ -n "$model" ]] && CLAUDE_MODELS+=("$model")
    done < <(curl -sf "$BASE_URL/v1/models" \
        -H "Authorization: Bearer $API_KEY" 2>/dev/null | \
        grep -oE '"id" *: *"claude[^"]*"' | \
        grep -oE 'claude[^"]+' | \
        sort -r)

    if [[ ${#CLAUDE_MODELS[@]} -gt 0 ]]; then
        echo "Available Claude models:"
        i=1
        for m in "${CLAUDE_MODELS[@]}"; do
            label="  $i) $m"
            [[ "$m" == "claude-sonnet-4-6" ]] && label+=" (recommended)"
            echo "$label"
            ((i++))
        done
        echo ""
        read -rp "Select model [press Enter to leave unset]: " model_choice
        if [[ "$model_choice" =~ ^[0-9]+$ && "$model_choice" -ge 1 && "$model_choice" -le "${#CLAUDE_MODELS[@]}" ]]; then
            ANTHROPIC_MODEL="${CLAUDE_MODELS[$((model_choice - 1))]}"
            echo "Selected: $ANTHROPIC_MODEL"
        fi
    else
        echo "  Could not fetch model list — enter model ID manually:"
        read -rep "  ANTHROPIC_MODEL [claude-sonnet-4-6]: " ANTHROPIC_MODEL
        ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-sonnet-4-6}"
    fi
    echo ""
fi

# SSH directory
read -rep "SSH key directory [~/.ssh] (press Enter to use default, 'skip' to skip mount): " SSH_INPUT
if [[ "${SSH_INPUT,,}" == "skip" ]]; then
    SSH_DIR=""
else
    SSH_DIR="${SSH_INPUT:-$HOME/.ssh}"
fi

# Workspace directory
read -rep "Default workspace directory (press Enter to leave unset — uses \$PWD at runtime): " WORKDIR_INPUT

# Write .env
cat > "$ENV_FILE" <<EOF
# Auth
DEFAULT_AUTH=${AUTH_MODE}
ANTHROPIC_API_KEY=${API_KEY}
ANTHROPIC_BASE_URL=${BASE_URL}
ANTHROPIC_MODEL=${ANTHROPIC_MODEL}

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

# Seed .omc-config.json so OMC skips its interactive setup wizard on first launch
# (without this, omc-setup spawns a planner agent requesting opus, which FuelIX doesn't license)
echo "  Seeding .omc-config.json..."
OMC_VERSION=$(docker run --rm claude-code:omc node -e \
    "console.log(require('/usr/local/lib/node_modules/oh-my-claudecode/package.json').version)" \
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
    echo "  - Approve the TELUS managed settings dialog — happens once per fresh .home/"
fi
echo "=========================================="
