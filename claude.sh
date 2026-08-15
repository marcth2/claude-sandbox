#!/bin/bash
set -euo pipefail

# Unsupported: native Windows shells (Git Bash, MSYS2, Cygwin) — use WSL2 instead
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "Error: unsupported shell environment '$(uname -s)'."
        echo "Run claude-docker from a WSL2 terminal, not PowerShell, Git Bash, or Cygwin."
        exit 1
        ;;
esac

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

    # Fixed display order; vanilla is the plain baseline and the default
    local ordered=(vanilla omc aihero)
    local -A descriptions=(
        [vanilla]="Claude Code, no plugins — plain baseline"
        [omc]="Claude Code + oh-my-claudecode multi-agent orchestration"
        [aihero]="Claude Code + AI Hero skill pack"
    )

    local profiles=()
    echo "Available profiles:"
    local i=1
    for name in "${ordered[@]}"; do
        [[ -d "$REPO_DIR/profiles/$name" ]] || continue
        profiles+=("$name")
        echo "  $i) $name — ${descriptions[$name]:-}"
        ((i++))
    done
    # Any unrecognized profiles not in the ordered list
    for d in "$REPO_DIR/profiles"/*/; do
        local name; name="$(basename "$d")"
        [[ " ${ordered[*]} " =~ " $name " ]] && continue
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

    bash "$REPO_DIR/profiles/$selected/setup.sh"

    # Alias setup — one place for all profiles
    echo ""

    # Pick shell config file based on OS and default shell
    # WSL/macOS paths are untested — logic based on standard conventions
    local aliases_file
    case "$(uname -s)" in
        Darwin*)
            if [[ "${SHELL:-}" == */zsh ]]; then
                aliases_file="$HOME/.zshrc"
            else
                aliases_file="$HOME/.bash_profile"
            fi
            ;;
        Linux*)
            aliases_file="$HOME/.bash_aliases"  # Linux and WSL
            ;;
        *)
            echo "Unknown OS — add alias manually:"
            echo "  alias <name>='${REPO_DIR}/claude.sh'"
            return 0
            ;;
    esac

    local alias_name alias_line existing_line existing_name

    # Search by repo path — finds entry regardless of alias name chosen last time
    existing_line=$(grep -E "^alias [^=]+='${REPO_DIR}/claude\.sh'" "$aliases_file" 2>/dev/null || true)

    if [[ -n "$existing_line" ]]; then
        existing_name=$(echo "$existing_line" | sed "s/^alias \([^=]*\)=.*/\1/")
        echo "Found existing alias for this install:"
        echo "  $existing_line"
        read -rp "Alias name [${existing_name}]: " alias_name
        alias_name="${alias_name:-$existing_name}"
        if [[ "$alias_name" != "$existing_name" ]]; then
            sed -i "/^alias ${existing_name}=/d" "$aliases_file"
            echo "alias ${alias_name}='${REPO_DIR}/claude.sh'" >> "$aliases_file"
            echo "Renamed to '${alias_name}'."
        fi
    else
        read -rp "Alias name [claude-sandbox]: " alias_name
        alias_name="${alias_name:-claude-sandbox}"
        if [[ -n "$alias_name" ]]; then
            alias_line="alias ${alias_name}='${REPO_DIR}/claude.sh'"
            if grep -qE "^alias ${alias_name}=" "$aliases_file" 2>/dev/null; then
                local conflict; conflict=$(grep -E "^alias ${alias_name}=" "$aliases_file")
                echo "Name '${alias_name}' already used:"
                echo "  $conflict"
                read -rp "Overwrite it? [y/N]: " overwrite
                if [[ "${overwrite,,}" == "y" ]]; then
                    sed -i "s|^alias ${alias_name}=.*|${alias_line}|" "$aliases_file"
                    echo "Updated."
                fi
            else
                echo "$alias_line" >> "$aliases_file"
                echo "Added."
            fi
        fi
    fi

    # Closing summary — source .env to read what setup wrote
    [[ -f "$REPO_DIR/.env" ]] && source "$REPO_DIR/.env"
    local launch_cmd="${alias_name:-$REPO_DIR/claude.sh}"
    echo ""
    echo "=========================================="
    echo "Setup complete!"
    echo ""
    echo "Configuration:"
    printf "  %-20s %s\n" "Profile:" "$selected"
    printf "  %-20s %s\n" "Default Auth:" "${DEFAULT_AUTH:-apikey}"
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        local key_mask; key_mask=$(printf '%*s' "${#ANTHROPIC_API_KEY}" '' | tr ' ' '*')
        printf "  %-20s %s\n" "API Key:" "$key_mask"
    fi
    [[ -n "${ANTHROPIC_BASE_URL:-}" ]] && printf "  %-20s %s\n" "Gateway:" "$ANTHROPIC_BASE_URL"
    if [[ -n "${ANTHROPIC_MODEL:-}" ]]; then
        printf "  %-20s %s\n" "Default Model:" "$ANTHROPIC_MODEL"
    else
        printf "  %-20s %s\n" "Default Model:" "(gateway default)"
    fi
    if [[ -n "${CLAUDE_WORKDIR:-}" ]]; then
        printf "  %-20s %s\n" "Default Workspace:" "$CLAUDE_WORKDIR"
    else
        printf "  %-20s %s\n" "Default Workspace:" "\$PWD at runtime"
    fi
    [[ -n "${SSH_DIR:-}" ]] && printf "  %-20s %s\n" "SSH keys:" "$SSH_DIR"
    if [[ "${DEFAULT_AUTH:-apikey}" == "sso" ]]; then
        echo ""
        echo "First-run notes:"
        echo "  - Look for a URL in the terminal — open it in your host browser"
        echo "  - Approve the org managed settings dialog (once per fresh .home/)"
    fi
    echo ""
    [[ -n "${alias_name:-}" ]] && echo "Run: source $aliases_file"
    echo "Run: $launch_cmd"
    echo "=========================================="
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
    echo "Reset complete. Run '${REPO_DIR}/claude.sh' again to set up a fresh profile."
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
