#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_FILE="$REPO_DIR/.claude-profile"

VERSION="$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo "unknown")"

usage() {
    cat <<EOF
claude-docker — Dockerized Claude Code launcher

Usage: claude-sandbox [OPTIONS] [-- CLAUDE_ARGS...]

Options:
  --auth=sso|apikey   Override default auth mode from .env
  --model=<id>        Override ANTHROPIC_MODEL for this invocation
  --workdir=<path>    Override working directory for this invocation
  --reset             Wipe .claude-profile, .env, and .home/ (requires confirmation)
  --help              Show this help and exit
  --version           Show claude-docker version and exit
  --                  Pass all following args directly to the claude binary

Auth modes:
  sso      OAuth via claude.ai (credentials stored in .home/)
  apikey   ANTHROPIC_AUTH_TOKEN via gateway (requires ANTHROPIC_API_KEY in .env)

To see claude's own help inside the container:
  claude-sandbox -- --help

Profile is locked per checkout. To try a different profile: clone the repo again.
EOF
}

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

do_reset() {
    local profile=""
    [[ -f "$PROFILE_FILE" ]] && profile=$(cat "$PROFILE_FILE")

    echo "=== Claude Docker — Reset ==="
    echo ""
    echo "This will permanently delete:"
    echo "  $PROFILE_FILE"
    echo "  $REPO_DIR/.env"
    echo "  $REPO_DIR/.home/"
    echo ""
    if [[ -n "$profile" ]]; then
        read -rp "Type the profile name '$profile' to confirm: " confirm
        if [[ "$confirm" != "$profile" ]]; then
            echo "Cancelled — profile name did not match."
            exit 1
        fi
    else
        read -rp "Type 'reset' to confirm: " confirm
        if [[ "$confirm" != "reset" ]]; then
            echo "Cancelled."
            exit 1
        fi
    fi

    rm -f "$PROFILE_FILE" "$REPO_DIR/.env"
    rm -rf "$REPO_DIR/.home"
    echo "Reset complete. Run claude-sandbox again to set up a fresh profile."
    exit 0
}

# Handle early flags before profile/env loading
case "${1:-}" in
    --help|-h)    usage; exit 0 ;;
    --version|-v) echo "claude-docker $VERSION"; exit 0 ;;
    --reset)      do_reset ;;
esac

if [[ ! -f "$PROFILE_FILE" ]]; then
    init
    exit 0
fi

PROFILE=$(cat "$PROFILE_FILE")
PROFILE_DIR="$REPO_DIR/profiles/$PROFILE"
ENV_FILE="$REPO_DIR/.env"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

AUTH="${DEFAULT_AUTH:-apikey}"
WORKDIR_OVERRIDE=""
MODEL_OVERRIDE=""
CLAUDE_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auth=*)    AUTH="${1#--auth=}"; shift ;;
        --auth)      AUTH="$2"; shift 2 ;;
        --model=*)   MODEL_OVERRIDE="${1#--model=}"; shift ;;
        --model)     MODEL_OVERRIDE="$2"; shift 2 ;;
        --workdir=*) WORKDIR_OVERRIDE="${1#--workdir=}"; shift ;;
        --workdir)   WORKDIR_OVERRIDE="$2"; shift 2 ;;
        --reset)     do_reset ;;
        --help|-h)   usage; exit 0 ;;
        --version|-v) echo "claude-docker $VERSION"; exit 0 ;;
        --)          shift; CLAUDE_ARGS+=("$@"); break ;;
        *)           CLAUDE_ARGS+=("$1"); shift ;;
    esac
done

WORKDIR="${WORKDIR_OVERRIDE:-${CLAUDE_WORKDIR:-$(pwd)}}"
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

# Image name from profile
case "$PROFILE" in
    omc) IMAGE="claude-code:omc" ;;
    *)   IMAGE="claude-code:base" ;;
esac

DOCKER_ARGS=(run --rm -it -w "$CONTAINERDIR")
DOCKER_ARGS+=(-v "$WORKDIR:$WORKDIR")
DOCKER_ARGS+=(-v "$REPO_DIR/.home:/home/marc")
DOCKER_ARGS+=(-v /var/run/docker.sock:/var/run/docker.sock)
DOCKER_ARGS+=(-e HOME=/home/marc)
DOCKER_ARGS+=(-e BROWSER=echo)
DOCKER_ARGS+=(--security-opt no-new-privileges:true)
DOCKER_ARGS+=(--cap-drop ALL)
DOCKER_ARGS+=(--memory 2g)
DOCKER_ARGS+=(--cpus 1.5)
DOCKER_ARGS+=(--pids-limit 256)
[[ -n "${SSH_DIR:-}" ]] && DOCKER_ARGS+=(-v "$SSH_DIR:/home/marc/.ssh:ro")
[[ -n "${DOCKER_GID:-}" ]] && DOCKER_ARGS+=(--group-add "$DOCKER_GID")

if [[ "$AUTH" == "apikey" ]]; then
    [[ -z "${ANTHROPIC_API_KEY:-}" ]] && { echo "Error: ANTHROPIC_API_KEY not set in .env"; exit 1; }
    DOCKER_ARGS+=(-e "ANTHROPIC_AUTH_TOKEN=$ANTHROPIC_API_KEY")
    [[ -n "${ANTHROPIC_BASE_URL:-}" ]] && DOCKER_ARGS+=(-e "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL")
    DOCKER_ARGS+=(-e "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1")
fi
# SSO: no auth env vars — Claude uses OAuth from .home/.claude.json

# Model override: --model flag takes priority over ANTHROPIC_MODEL in .env
EFFECTIVE_MODEL="${MODEL_OVERRIDE:-${ANTHROPIC_MODEL:-}}"
[[ -n "$EFFECTIVE_MODEL" ]] && DOCKER_ARGS+=(-e "ANTHROPIC_MODEL=$EFFECTIVE_MODEL")

# Verify image exists — if not, setup was likely interrupted
if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "Error: Docker image '$IMAGE' not found."
    echo "Setup may have been interrupted before the build completed."
    echo ""
    echo "Run: ./claude.sh --reset  (then re-run ./claude.sh to redo setup)"
    exit 1
fi

exec docker "${DOCKER_ARGS[@]}" "$IMAGE" "${CLAUDE_ARGS[@]}"
