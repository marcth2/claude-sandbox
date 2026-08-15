#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
HOME_DIR="$REPO_DIR/.home"

echo "=== Claude Docker — aihero Profile Setup ==="
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

read -rp "Default auth mode [sso/apikey] (default: sso): " AUTH_MODE
AUTH_MODE="${AUTH_MODE:-sso}"

read -rp "ANTHROPIC_API_KEY (press Enter to skip): " API_KEY

read -rp "ANTHROPIC_BASE_URL (press Enter for api.anthropic.com): " BASE_URL

SSH_DIR=""
read -rp "SSH key directory (press Enter to skip mount): " SSH_INPUT
if [[ -z "$SSH_INPUT" && -d "$HOME/.ssh" ]]; then
    read -rp "  Found ~/.ssh — mount it? [y/N]: " MOUNT_SSH
    [[ "${MOUNT_SSH,,}" == "y" ]] && SSH_DIR="$HOME/.ssh"
elif [[ -n "$SSH_INPUT" ]]; then
    SSH_DIR="$SSH_INPUT"
fi

read -rp "Default workspace directory [$PWD]: " WORKDIR_INPUT
WORKDIR_INPUT="${WORKDIR_INPUT:-$PWD}"

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

echo ""
echo "Building claude-code:base image..."
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
    "ANTHROPIC_MODEL": "claude-sonnet-4-6",
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

# Run aihero plugin install as a one-off container seeding .home/
echo ""
echo "Installing aihero plugin (mattpocock-skills) into .home/..."
docker compose -f "$PROFILE_DIR/docker-compose.yml" run --rm \
    -v "$HOME_DIR:/home/marc" \
    -e HOME=/home/marc \
    claude plugins install mattpocock-skills
echo "Plugin install complete — skills persisted in .home/.claude/"

echo ""
echo "=========================================="
echo "Setup complete!"
echo ""
echo "Add this alias to ~/.bash_aliases:"
echo ""
echo "  alias claude='$REPO_DIR/claude.sh'"
echo ""
echo "Or with explicit auth default:"
echo "  alias claude='$REPO_DIR/claude.sh --auth=${AUTH_MODE}'"
echo ""
echo "Then run: source ~/.bash_aliases"
echo ""
echo "First-run notes:"
if [[ "$AUTH_MODE" == "sso" ]]; then
    echo "  - SSO: Look for a URL in the terminal — open it in your host browser"
fi
echo "  - Approve the TELUS managed settings dialog — happens once per profile"
echo "=========================================="
