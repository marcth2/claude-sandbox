#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
HOME_DIR="$REPO_DIR/.home"

echo "=== Claude Docker — vanilla Profile Setup ==="
echo ""

OS="linux"
if [[ "$(uname -s)" == "Darwin" ]]; then
    OS="macos"
elif grep -qi microsoft /proc/version 2>/dev/null; then
    OS="wsl"
fi
echo "Detected OS: $OS"

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

read -rp "Default auth mode [sso/apikey] (default: apikey): " AUTH_MODE
AUTH_MODE="${AUTH_MODE:-apikey}"

echo "ANTHROPIC_BASE_URL:"
echo "  1) https://api.anthropic.com (default)"
echo "  2) https://api.fuelix.ai (FueliX)"
echo "  3) Other / skip"
read -rp "  Choice [1]: " BASE_URL_CHOICE
case "${BASE_URL_CHOICE:-1}" in
    1) BASE_URL="https://api.anthropic.com" ;;
    2) BASE_URL="https://api.fuelix.ai" ;;
    3) read -rp "  Enter URL (press Enter to leave blank): " BASE_URL ;;
    *) BASE_URL="https://api.anthropic.com" ;;
esac

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
        default_idx=1
        i=1
        for m in "${CLAUDE_MODELS[@]}"; do
            label="  $i) $m"
            if [[ "$m" == "claude-sonnet-5" ]]; then
                label+=" (recommended)"
                default_idx=$i
            fi
            echo "$label"
            ((i++))
        done
        echo ""
        read -rp "Select model [${default_idx}]: " model_choice
        model_choice="${model_choice:-$default_idx}"
        if [[ "$model_choice" =~ ^[0-9]+$ && "$model_choice" -ge 1 && "$model_choice" -le "${#CLAUDE_MODELS[@]}" ]]; then
            ANTHROPIC_MODEL="${CLAUDE_MODELS[$((model_choice - 1))]}"
            echo "Selected: $ANTHROPIC_MODEL"
        fi
    else
        echo "  Could not fetch model list — enter model ID manually:"
        read -rep "  ANTHROPIC_MODEL [claude-sonnet-5]: " ANTHROPIC_MODEL
        ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-sonnet-5}"
    fi
    echo ""
fi

read -rep "SSH key directory [~/.ssh] (press Enter to use default, 'skip' to skip mount): " SSH_INPUT
if [[ "${SSH_INPUT,,}" == "skip" ]]; then
    SSH_DIR=""
else
    SSH_DIR="${SSH_INPUT:-$HOME/.ssh}"
fi

read -rep "Default workspace directory (press Enter to leave unset — uses \$PWD at runtime): " WORKDIR_INPUT

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

echo ""
echo "Building claude-code:base image..."
export DOCKER_GID
docker compose -f "$PROFILE_DIR/docker-compose.yml" build
echo "Build complete."

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
  "theme": "dark"
}
SETTINGS
echo "  settings.json written."

