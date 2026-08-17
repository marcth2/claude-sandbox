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

declare -A _INIT_ROW_START=()
declare -A _INIT_ROW_COUNT=()

# Recomputes the profile-picker box's interior content top to bottom and
# records where each row starts (_INIT_ROW_START) and how many physical
# lines it currently occupies (_INIT_ROW_COUNT) — mirrors _dash_layout in
# profiles/_common.sh so a long profile description would wrap safely too.
_init_layout_profiles() {
    _INIT_LINES=()
    ui_box_compose "${UI_BOLD}${UI_BLUE}claude-sandbox — First-Run Setup${UI_RESET}"
    _INIT_LINES+=("${UI_BOX_LINES[@]}")
    ui_box_compose "${UI_DIM}Up/Down move   Enter selects${UI_RESET}"
    _INIT_LINES+=("${UI_BOX_LINES[@]}")
    ui_box_compose ""
    _INIT_LINES+=("${UI_BOX_LINES[@]}")

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
        ui_box_compose "$(printf '%s%s' "$marker" "$label")"
        _INIT_ROW_START[$i]=${#_INIT_LINES[@]}
        _INIT_ROW_COUNT[$i]=${#UI_BOX_LINES[@]}
        _INIT_LINES+=("${UI_BOX_LINES[@]}")
    done

    ui_box_compose ""
    _INIT_LINES+=("${UI_BOX_LINES[@]}")
    ui_box_compose "${UI_DIM}Locked for this checkout — no --profile override. Clone the repo again for another.${UI_RESET}"
    _INIT_LINES+=("${UI_BOX_LINES[@]}")
    return 0
}

_init_draw_full() {
    _init_layout_profiles
    clear
    ui_box_top
    local i n=${#_INIT_LINES[@]}
    for ((i = 0; i < n; i++)); do
        tput cup $((i + 1)) 0 2>/dev/null || true
        printf '%s' "${_INIT_LINES[$i]}"
    done
    tput cup $((n + 1)) 0 2>/dev/null || true
    ui_box_bottom
    return 0
}

# Redraws just one profile row in place, at its last-computed position — used
# for pure Up/Down movement so navigating the picker doesn't repaint (and
# flicker) the whole box. Same technique as _dash_redraw_row.
_init_redraw_row() {
    local i="$1" marker label
    marker="  "
    if ((i == _INIT_SEL)); then
        marker="${UI_BOLD}${UI_BLUE}> ${UI_RESET}"
    fi
    label="${_INIT_PROFILES[$i]}"
    if [[ -n "${_INIT_DESCS[$i]}" ]]; then
        label="$label — ${_INIT_DESCS[$i]}"
    fi
    ui_box_compose "$(printf '%s%s' "$marker" "$label")"
    local start="${_INIT_ROW_START[$i]}" j n=${#UI_BOX_LINES[@]}
    for ((j = 0; j < n; j++)); do
        tput cup $((start + j + 1)) 0 2>/dev/null || true
        tput el 2>/dev/null || true
        printf '%s' "${UI_BOX_LINES[$j]}"
    done
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
    _init_draw_full
    local key done_sel="" old_sel
    while [[ -z "$done_sel" ]]; do
        key=$(ui_read_key)
        case "$key" in
            UP)
                old_sel=$_INIT_SEL
                _INIT_SEL=$(((_INIT_SEL - 1 + ${#_INIT_PROFILES[@]}) % ${#_INIT_PROFILES[@]}))
                _init_redraw_row "$old_sel"
                _init_redraw_row "$_INIT_SEL"
                ;;
            DOWN)
                old_sel=$_INIT_SEL
                _INIT_SEL=$(((_INIT_SEL + 1) % ${#_INIT_PROFILES[@]}))
                _init_redraw_row "$old_sel"
                _init_redraw_row "$_INIT_SEL"
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

    # The shell-alias prompt used to run here, before setup.sh. It's now the
    # last dashboard row (right before CONFIRM) inside profiles/_common.sh's
    # _common_ensure_dashboard — see that file's _dash_apply_alias for why
    # (its resolved name/rc-file are handed back via the .claude-alias
    # marker file read below, not a shared variable).
    bash "$REPO_DIR/profiles/$selected/setup.sh"

    # Closing summary — source .env to read what setup wrote, and the
    # .claude-alias marker file for what the alias prompt (run inside
    # setup.sh) decided.
    [[ -f "$REPO_DIR/.env" ]] && source "$REPO_DIR/.env"
    local alias_name="" alias_rcfile=""
    if [[ -f "$REPO_DIR/.claude-alias" ]]; then
        {
            read -r alias_name
            read -r alias_rcfile
        } <"$REPO_DIR/.claude-alias"
    fi
    local launch_cmd="${alias_name:-$REPO_DIR/claude.sh}"
    echo ""
    echo "============================================================"
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
    [[ -n "$alias_name" ]] && printf "  %-20s %s\n" "Shell Alias:" "$alias_name"
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
    # /gh-login is passed as claude's first message so gh auth happens
    # automatically on first launch — see profiles/_common.sh's
    # common_seed_gh_skill for the skill this triggers.
    if [[ -n "$alias_name" && -n "$alias_rcfile" ]]; then
        echo "Run: source $alias_rcfile && $launch_cmd /gh-login"
    else
        echo "Run: $launch_cmd /gh-login"
    fi
    echo "============================================================"
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
