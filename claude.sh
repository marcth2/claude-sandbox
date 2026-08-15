#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_FILE="$REPO_DIR/.claude-profile"

init() {
    echo "=== Claude Docker — First Run Setup ==="
    echo ""
    echo "Available profiles:"
    local i=1
    local profiles=()
    for d in "$REPO_DIR/profiles"/*/; do
        local name
        name="$(basename "$d")"
        profiles+=("$name")
        echo "  $i) $name"
        ((i++))
    done
    echo ""
    read -rp "Select profile [1]: " choice
    choice="${choice:-1}"
    local idx=$((choice - 1))
    local selected="${profiles[$idx]}"
    echo "$selected" > "$PROFILE_FILE"
    echo "Profile '$selected' selected."
    echo ""
    exec "$REPO_DIR/profiles/$selected/setup.sh"
}

if [[ ! -f "$PROFILE_FILE" ]]; then
    init
    exit 0
fi

PROFILE=$(cat "$PROFILE_FILE")
PROFILE_DIR="$REPO_DIR/profiles/$PROFILE"
ENV_FILE="$REPO_DIR/.env"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

AUTH="${DEFAULT_AUTH:-sso}"
CLAUDE_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auth=*) AUTH="${1#--auth=}"; shift ;;
        --auth)   AUTH="$2"; shift 2 ;;
        --)       shift; CLAUDE_ARGS+=("$@"); break ;;
        *)        CLAUDE_ARGS+=("$1"); shift ;;
    esac
done

WORKDIR="${CLAUDE_WORKDIR:-$(pwd)}"
if [[ "$PWD" == "$WORKDIR"* ]]; then
    CONTAINERDIR="$PWD"
else
    CONTAINERDIR="$WORKDIR"
fi

# Docker GID: detect on Linux/WSL, skip on macOS (Docker Desktop handles it)
DOCKER_GID=""
case "$(uname -s)" in
    Linux*)  DOCKER_GID=$(getent group docker | cut -d: -f3 2>/dev/null || echo "984") ;;
    Darwin*) ;;
esac
export DOCKER_GID

DOCKER_ARGS=(run --rm -it -w "$CONTAINERDIR")
DOCKER_ARGS+=(-v "$WORKDIR:$WORKDIR")
DOCKER_ARGS+=(-v "$REPO_DIR/.home:/home/marc")
[[ -n "${SSH_DIR:-}" ]] && DOCKER_ARGS+=(-v "$SSH_DIR:/home/marc/.ssh:ro")
[[ -n "${DOCKER_GID:-}" ]] && DOCKER_ARGS+=(--group-add "$DOCKER_GID")

if [[ "$AUTH" == "apikey" ]]; then
    [[ -z "${ANTHROPIC_API_KEY:-}" ]] && { echo "Error: ANTHROPIC_API_KEY not set in .env"; exit 1; }
    DOCKER_ARGS+=(-e "ANTHROPIC_AUTH_TOKEN=$ANTHROPIC_API_KEY")
    [[ -n "${ANTHROPIC_BASE_URL:-}" ]] && DOCKER_ARGS+=(-e "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL")
fi
# SSO: no auth env vars — Claude uses OAuth from .home/.claude.json

exec docker compose -f "$PROFILE_DIR/docker-compose.yml" "${DOCKER_ARGS[@]}" claude "${CLAUDE_ARGS[@]}"
