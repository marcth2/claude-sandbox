#!/bin/bash
set -euo pipefail

# Unsupported: native Windows shells (Git Bash, MSYS2, Cygwin) — use WSL2 instead
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
        echo "Error: unsupported shell environment '$(uname -s)'."
        echo "Run claude-sandbox from a WSL2 terminal, not PowerShell, Git Bash, or Cygwin."
        exit 1
        ;;
esac

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_FILE="$REPO_DIR/.claude-profile"

VERSION="$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo "unknown")"

usage() {
    cat <<EOF
claude-sandbox — Dockerized Claude Code launcher

Usage: claude-sandbox [OPTIONS] [-- CLAUDE_ARGS...]

Options:
  --auth=sso|apikey   Override default auth mode from .env
  --model=<id>        Override ANTHROPIC_MODEL for this invocation
  --workdir=<path>    Override working directory for this invocation
  --confirm           Use Claude Code's real permission prompts instead of
                      --dangerously-skip-permissions
  --recover           Wipe and rebuild .env and .home/ for this checkout's
                      already-selected profile (requires confirmation). Does
                      NOT let you change profiles — clone the repo again for
                      that.
  --help, -h          Show this help and exit
  --version, -v       Show claude-sandbox version and exit
  --                  Pass all following args directly to the claude binary

Auth modes:
  sso      OAuth via claude.ai (credentials stored in .home/)
  apikey   ANTHROPIC_AUTH_TOKEN via gateway (requires ANTHROPIC_API_KEY in .env)

To see claude's own help inside the container:
  claude-sandbox -- --help

Profile is locked per checkout. To try a different profile: clone the repo again.
EOF
}

_profile_desc() {
    case "$1" in
        vanilla) echo "Claude Code, no plugins — plain baseline" ;;
        omc) echo "Claude Code + oh-my-claude-sisyphus multi-agent orchestration" ;;
        aihero) echo "Claude Code + AI Hero skill pack" ;;
        *) echo "" ;;
    esac
}

# --- init() helpers -------------------------------------------------------
# Kept as top-level functions (not nested in init()) using a small set of
# global _INIT_* scratch variables, the same pattern profiles/_common.sh's
# dashboard uses for its own state — avoids relying on bash's dynamic
# scoping of init()'s locals, which static tools like shellcheck can't see
# through.

_init_draw_profiles() {
    clear
    ui_box_top
    ui_box_line "${UI_BOLD}${UI_BLUE}claude-sandbox — First-Run Setup${UI_RESET}"
    ui_box_line "${UI_DIM}Up/Down move   Enter selects${UI_RESET}"
    ui_box_line ""
    local i marker label
    for ((i = 0; i < ${#_INIT_PROFILES[@]}; i++)); do
        marker="  "
        if ((i == _INIT_SEL)); then
            marker="${UI_BOLD}${UI_BLUE}> ${UI_RESET}"
        fi
        label="${_INIT_PROFILES[$i]}"
        if [[ -n "${_INIT_DESCS[$i]}" ]]; then
            label="$label — ${_INIT_DESCS[$i]}"
        fi
        ui_box_line "$(printf '%s%s' "$marker" "$label")"
    done
    ui_box_line ""
    ui_box_line "${UI_DIM}Locked for this checkout — no --profile override. Clone the repo again for another.${UI_RESET}"
    ui_box_bottom
    return 0
}

_init_draw_alias_box() {
    clear
    ui_box_top
    ui_box_line "${UI_BOLD}${UI_BLUE}claude-sandbox — Shell Alias${UI_RESET}"
    ui_box_line "${UI_DIM}Pick a short command to launch claude-sandbox from your shell.${UI_RESET}"
    ui_box_bottom
    return 0
}

# Gathers alias name/action into _INIT_ALIAS_* globals. Pure input-gathering
# — no file writes here (see _init_alias_apply) — so this is the part that
# has to happen before the docker build, alongside the other prompts.
_init_alias_gather() {
    local aliases_file=""
    case "$(uname -s)" in
        Darwin*)
            if [[ "${SHELL:-}" == */zsh ]]; then
                aliases_file="$HOME/.zshrc"
            else
                aliases_file="$HOME/.bash_profile"
            fi
            ;;
        Linux*)
            aliases_file="$HOME/.bash_aliases" # Linux and WSL
            ;;
        *)
            aliases_file="" # WSL/macOS paths are untested — logic based on standard conventions
            ;;
    esac
    _INIT_ALIASES_FILE="$aliases_file"
    _INIT_ALIAS_NAME=""
    _INIT_ALIAS_ACTION="none"
    _INIT_ALIAS_OLD_NAME=""

    if [[ -z "$aliases_file" ]]; then
        return 0
    fi

    ui_cursor_show
    echo ""
    local existing_line existing_name
    # Search by repo path — finds entry regardless of alias name chosen last time
    existing_line=$(grep -E "^alias [^=]+='${REPO_DIR}/claude\.sh'" "$aliases_file" 2>/dev/null || true)

    if [[ -n "$existing_line" ]]; then
        existing_name="${existing_line#alias }"
        existing_name="${existing_name%%=*}"
        echo "Found existing alias for this install:"
        echo "  $existing_line"
        read -rp "Alias name [${existing_name}]: " _INIT_ALIAS_NAME
        _INIT_ALIAS_NAME="${_INIT_ALIAS_NAME:-$existing_name}"
        _INIT_ALIAS_NAME="${_INIT_ALIAS_NAME//[^a-zA-Z0-9_-]/}"
        if [[ -z "$_INIT_ALIAS_NAME" ]]; then
            _INIT_ALIAS_NAME="$existing_name"
        fi
        if [[ "$_INIT_ALIAS_NAME" != "$existing_name" ]]; then
            _INIT_ALIAS_ACTION="rename"
            _INIT_ALIAS_OLD_NAME="$existing_name"
        fi
    else
        read -rp "Alias name [claude-sandbox]: " _INIT_ALIAS_NAME
        _INIT_ALIAS_NAME="${_INIT_ALIAS_NAME:-claude-sandbox}"
        _INIT_ALIAS_NAME="${_INIT_ALIAS_NAME//[^a-zA-Z0-9_-]/}"
        if [[ -z "$_INIT_ALIAS_NAME" ]]; then
            _INIT_ALIAS_NAME="claude-sandbox"
        fi
        if grep -qE "^alias ${_INIT_ALIAS_NAME}=" "$aliases_file" 2>/dev/null; then
            local conflict
            conflict=$(grep -E "^alias ${_INIT_ALIAS_NAME}=" "$aliases_file")
            echo "Name '${_INIT_ALIAS_NAME}' already used:"
            echo "  $conflict"
            local overwrite=""
            read -rp "Overwrite it? [y/N]: " overwrite
            if [[ "${overwrite,,}" == "y" ]]; then
                _INIT_ALIAS_ACTION="overwrite"
            else
                _INIT_ALIAS_ACTION="skip"
            fi
        else
            _INIT_ALIAS_ACTION="add"
        fi
    fi
    ui_cursor_hide
    return 0
}

# Applies whatever _init_alias_gather decided. Just a file write plus a
# confirmation echo — not interactive — so it runs after ui_alt_exit, where
# the confirmation lands in normal scrollback instead of being wiped when
# the alt screen closes.
_init_alias_apply() {
    if [[ -z "$_INIT_ALIASES_FILE" ]]; then
        echo "Unknown OS — add alias manually:"
        echo "  alias <name>='${REPO_DIR}/claude.sh'"
        return 0
    fi
    case "$_INIT_ALIAS_ACTION" in
        rename)
            sed -i "/^alias ${_INIT_ALIAS_OLD_NAME}=/d" "$_INIT_ALIASES_FILE"
            echo "alias ${_INIT_ALIAS_NAME}='${REPO_DIR}/claude.sh'" >>"$_INIT_ALIASES_FILE"
            echo "Renamed to '${_INIT_ALIAS_NAME}'."
            ;;
        overwrite)
            sed -i "s|^alias ${_INIT_ALIAS_NAME}=.*|alias ${_INIT_ALIAS_NAME}='${REPO_DIR}/claude.sh'|" "$_INIT_ALIASES_FILE"
            echo "Updated."
            ;;
        add)
            echo "alias ${_INIT_ALIAS_NAME}='${REPO_DIR}/claude.sh'" >>"$_INIT_ALIASES_FILE"
            echo "Added."
            ;;
        skip | none) : ;;
    esac
    return 0
}

init() {
    # shellcheck source=profiles/_common.sh
    source "$REPO_DIR/profiles/_common.sh"
    ui_init

    echo "${UI_BOLD}claude-sandbox — First-Run Setup${UI_RESET}"
    echo ""

    # Fixed display order; vanilla is the plain baseline and the default
    local ordered=(vanilla omc aihero)
    _INIT_PROFILES=()
    _INIT_DESCS=()
    local name desc d
    for name in "${ordered[@]}"; do
        [[ -d "$REPO_DIR/profiles/$name" ]] || continue
        desc="$(_profile_desc "$name")"
        _INIT_PROFILES+=("$name")
        _INIT_DESCS+=("$desc")
    done
    # Any unrecognized profiles not in the ordered list
    for d in "$REPO_DIR/profiles"/*/; do
        name="$(basename "$d")"
        [[ " ${ordered[*]} " == *" $name "* ]] && continue
        _INIT_PROFILES+=("$name")
        _INIT_DESCS+=("")
    done

    _INIT_SEL=0
    ui_alt_enter
    _init_draw_profiles
    local key done_sel=""
    while [[ -z "$done_sel" ]]; do
        key=$(ui_read_key)
        case "$key" in
            UP)
                _INIT_SEL=$(((_INIT_SEL - 1 + ${#_INIT_PROFILES[@]}) % ${#_INIT_PROFILES[@]}))
                _init_draw_profiles
                ;;
            DOWN)
                _INIT_SEL=$(((_INIT_SEL + 1) % ${#_INIT_PROFILES[@]}))
                _init_draw_profiles
                ;;
            ENTER) done_sel=1 ;;
            *) : ;;
        esac
    done
    ui_alt_exit

    local selected="${_INIT_PROFILES[$_INIT_SEL]}"
    echo "$selected" >"$PROFILE_FILE"
    echo ""
    echo "${UI_GREEN}Profile '$selected' selected${UI_RESET} — locked for this checkout."

    # Alias prompt happens here, up front with the rest of the interactive
    # questions, not after the build — only the actual gathering needs to be
    # interactive; _init_alias_apply is just a file write and runs right
    # after so its confirmation message is visible in normal scrollback.
    ui_alt_enter
    _init_draw_alias_box
    _init_alias_gather
    ui_alt_exit
    _init_alias_apply

    bash "$REPO_DIR/profiles/$selected/setup.sh"

    # Closing summary — source .env to read what setup wrote
    [[ -f "$REPO_DIR/.env" ]] && source "$REPO_DIR/.env"
    local launch_cmd="${_INIT_ALIAS_NAME:-$REPO_DIR/claude.sh}"
    echo ""
    echo "=========================================="
    echo "Setup complete!"
    echo ""
    echo "Configuration:"
    printf "  %-20s %s\n" "Profile:" "$selected"
    printf "  %-20s %s\n" "Default Auth:" "${DEFAULT_AUTH:-apikey}"
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        local key_mask
        key_mask=$(printf '%*s' "${#ANTHROPIC_API_KEY}" '' | tr ' ' '*')
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
    local gitconfig="$REPO_DIR/.home/.gitconfig"
    if [[ -f "$gitconfig" ]]; then
        local git_name git_email
        git_name=$(git config --file "$gitconfig" user.name 2>/dev/null || echo "")
        git_email=$(git config --file "$gitconfig" user.email 2>/dev/null || echo "")
        [[ -n "$git_name" || -n "$git_email" ]] && printf "  %-20s %s\n" "Git identity:" "$git_name <$git_email>"
    else
        printf "  %-20s %s\n" "Git identity:" "(not set — commits inside container will fail until configured)"
    fi
    if [[ "${DEFAULT_AUTH:-apikey}" == "sso" ]]; then
        echo ""
        echo "First-run notes:"
        echo "  - Look for a URL in the terminal — open it in your host browser"
        echo "  - Approve the org managed settings dialog (once per fresh .home/)"
    fi
    echo ""
    if [[ -n "${_INIT_ALIAS_NAME:-}" && -n "${_INIT_ALIASES_FILE:-}" ]]; then
        echo "Run: source $_INIT_ALIASES_FILE"
    fi
    echo "Run: $launch_cmd"
    echo ""
    echo "Once inside Claude Code, run /gh-login once to authenticate gh"
    echo "(needed for git push / PR / issue operations from the container)."
    echo "=========================================="
}

do_recover() {
    if [[ ! -f "$PROFILE_FILE" ]]; then
        echo "Error: no profile selected yet — nothing to recover."
        echo "Run '${REPO_DIR}/claude.sh' to set up a profile first."
        exit 1
    fi

    local profile
    profile=$(cat "$PROFILE_FILE")

    if [[ ! -f "$REPO_DIR/profiles/$profile/setup.sh" ]]; then
        echo "Error: profile '$profile' no longer exists in this checkout"
        echo "(profiles/$profile/setup.sh not found)."
        echo "Recovery can't re-run setup for a profile that's gone. Clone the"
        echo "repo again to pick a currently available profile."
        exit 1
    fi

    echo "=== Claude Docker — Recover ==="
    echo ""
    echo "This will permanently delete and re-create:"
    echo "  $REPO_DIR/.env"
    echo "  $REPO_DIR/.home/"
    echo ""
    echo "Profile stays locked to '$profile' — this does NOT let you switch"
    echo "profiles. To use a different profile, clone the repo again."
    echo ""
    read -rp "Type the profile name '$profile' to confirm: " confirm
    if [[ "$confirm" != "$profile" ]]; then
        echo "Cancelled — profile name did not match."
        exit 1
    fi

    rm -f "$REPO_DIR/.env"
    rm -rf "$REPO_DIR/.home"
    echo ""
    echo "Wiped .env and .home/. Re-running setup for profile '$profile'..."
    echo ""
    bash "$REPO_DIR/profiles/$profile/setup.sh"
    echo ""
    echo "Recovery complete. Run '${REPO_DIR}/claude.sh' to launch."
    exit 0
}

# Handle early flags before profile/env loading
case "${1:-}" in
    --help | -h)
        usage
        exit 0
        ;;
    --version | -v)
        echo "claude-sandbox $VERSION"
        exit 0
        ;;
    --recover) do_recover ;;
esac

if [[ ! -f "$PROFILE_FILE" ]]; then
    init
    exit 0
fi

PROFILE=$(cat "$PROFILE_FILE")
ENV_FILE="$REPO_DIR/.env"

# shellcheck disable=SC1090  # dynamically generated, gitignored file — no static path to follow
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

CONTAINER_HOME="/home/${CONTAINER_USER:-$(id -un)}"

AUTH="${DEFAULT_AUTH:-apikey}"
WORKDIR_OVERRIDE=""
MODEL_OVERRIDE=""
CONFIRM=false
CLAUDE_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auth=*)
            AUTH="${1#--auth=}"
            shift
            ;;
        --auth)
            AUTH="$2"
            shift 2
            ;;
        --model=*)
            MODEL_OVERRIDE="${1#--model=}"
            shift
            ;;
        --model)
            MODEL_OVERRIDE="$2"
            shift 2
            ;;
        --workdir=*)
            WORKDIR_OVERRIDE="${1#--workdir=}"
            shift
            ;;
        --workdir)
            WORKDIR_OVERRIDE="$2"
            shift 2
            ;;
        --confirm)
            CONFIRM=true
            shift
            ;;
        --recover) do_recover ;;
        --help | -h)
            usage
            exit 0
            ;;
        --version | -v)
            echo "claude-sandbox $VERSION"
            exit 0
            ;;
        --)
            shift
            CLAUDE_ARGS+=("$@")
            break
            ;;
        *)
            CLAUDE_ARGS+=("$1")
            shift
            ;;
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
    Linux*) DOCKER_GID=$(getent group docker | cut -d: -f3 2>/dev/null || echo "984") ;;
    Darwin*) ;;
esac

# Image name from profile
case "$PROFILE" in
    omc) IMAGE="claude-code:omc" ;;
    *) IMAGE="claude-code:base" ;;
esac

DOCKER_ARGS=(run --rm -it -w "$CONTAINERDIR")
# --dangerously-skip-permissions is baked into the image's ENTRYPOINT. --confirm
# overrides the entrypoint to plain `claude`, dropping that flag so Claude Code's
# real allow/deny prompts are used instead.
[[ "$CONFIRM" == "true" ]] && DOCKER_ARGS+=(--entrypoint claude)
DOCKER_ARGS+=(-v "$WORKDIR:$WORKDIR")
DOCKER_ARGS+=(-v "$REPO_DIR/.home:$CONTAINER_HOME")
DOCKER_ARGS+=(-v /var/run/docker.sock:/var/run/docker.sock)
DOCKER_ARGS+=(-e "HOME=$CONTAINER_HOME")
DOCKER_ARGS+=(-e BROWSER=echo)
DOCKER_ARGS+=(--security-opt no-new-privileges:true)
DOCKER_ARGS+=(--cap-drop ALL)
DOCKER_ARGS+=(--memory 2g)
DOCKER_ARGS+=(--cpus 1.5)
DOCKER_ARGS+=(--pids-limit 256)
# Structural containment: rootfs is read-only, so anything writing outside
# .home/, the workdir, or /tmp fails loudly instead of landing somewhere
# unmounted and un-inspected. /tmp gets its own writable tmpfs since tools
# (git, npm, claude itself) commonly need real scratch space there.
DOCKER_ARGS+=(--read-only)
# shellcheck disable=SC2054  # comma is part of docker's --tmpfs option syntax, not an array separator
DOCKER_ARGS+=(--tmpfs /tmp:rw,size=512m)
[[ -n "${SSH_DIR:-}" ]] && DOCKER_ARGS+=(-v "$SSH_DIR:$CONTAINER_HOME/.ssh:ro")
[[ -n "${DOCKER_GID:-}" ]] && DOCKER_ARGS+=(--group-add "$DOCKER_GID")

if [[ "$AUTH" == "apikey" ]]; then
    [[ -z "${ANTHROPIC_API_KEY:-}" ]] && {
        echo "Error: ANTHROPIC_API_KEY not set in .env"
        exit 1
    }
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
    echo "Run: ./claude.sh --recover  (rebuilds .env/.home/ for the '$PROFILE' profile)"
    exit 1
fi

exec docker "${DOCKER_ARGS[@]}" "$IMAGE" "${CLAUDE_ARGS[@]}"
