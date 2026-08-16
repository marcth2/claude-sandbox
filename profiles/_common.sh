#!/bin/bash
# Sourced by each profile's setup.sh — do not run directly.
# Caller must set: REPO_DIR, PROFILE_DIR, ENV_FILE, HOME_DIR

common_detect_os() {
    OS="linux"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        OS="macos"
    elif grep -qi microsoft /proc/version 2>/dev/null; then
        OS="wsl"
    fi
    echo "Detected OS: $OS"

    DOCKER_GID=""
    case "$OS" in
        linux | wsl)
            DOCKER_GID=$(getent group docker | cut -d: -f3 2>/dev/null || echo "984")
            echo "Docker GID: $DOCKER_GID"
            ;;
        macos)
            echo "macOS: Docker Desktop handles socket permissions — no GID needed."
            ;;
    esac

    CONTAINER_USER=$(id -un)
    CONTAINER_UID=$(id -u)
    CONTAINER_GID=$(id -g)
    echo ""
}

# ---------------------------------------------------------------------------
# Direction C — "Dashboard Table": one color-coded screen for auth + mounts +
# git identity, arrow-key navigation across every row, single Enter-on-CONFIRM
# to commit. common_prompt_auth/common_prompt_mounts/common_prompt_git are the
# three call sites every profile's setup.sh invokes (unchanged names/order);
# they all funnel into _common_ensure_dashboard, which runs the real
# interactive loop exactly once and is a no-op on the later two calls.
# ---------------------------------------------------------------------------

_dash_layout() {
    LINE_TITLE=0
    LINE_HINT=1
    LINE_PROFILE=3
    LINE_AUTH=5
    LINE_BASEURL=6
    LINE_APIKEY=7
    LINE_MODEL=8
    LINE_SSH=10
    LINE_WORKDIR=11
    LINE_GITNAME=13
    LINE_GITEMAIL=14
    LINE_CONFIRM=16
    LINE_HELP=18
    LINE_STATUS=19
    DASH_TOTAL_LINES=21
}

_dash_colors() {
    _DASH_BOLD=$(tput bold 2>/dev/null || true)
    _DASH_DIM=$(tput dim 2>/dev/null || true)
    _DASH_RESET=$(tput sgr0 2>/dev/null || true)
    _DASH_RED=$(tput setaf 1 2>/dev/null || true)
    _DASH_GREEN=$(tput setaf 2 2>/dev/null || true)
    _DASH_YELLOW=$(tput setaf 3 2>/dev/null || true)
    _DASH_CYAN=$(tput setaf 6 2>/dev/null || true)
}

_dash_cursor_hide() { tput civis 2>/dev/null || true; }
_dash_cursor_show() { tput cnorm 2>/dev/null || true; }
_dash_goto() { tput cup "$1" 0 2>/dev/null || true; }
_dash_clear_line() { tput el 2>/dev/null || true; }

# Reads one logical keypress: prints ENTER, UP, DOWN, ESC, or the literal
# character. Escape sequences (arrow keys) are two bytes after the ESC byte.
_dash_read_key() {
    local k rest
    IFS= read -rsn1 k || true
    if [[ -z "$k" ]]; then
        printf 'ENTER'
        return 0
    fi
    if [[ "$k" == $'\x1b' ]]; then
        IFS= read -rsn2 -t 0.05 rest 2>/dev/null || true
        case "$rest" in
            '[A') printf 'UP' ;;
            '[B') printf 'DOWN' ;;
            *) printf 'ESC' ;;
        esac
        return 0
    fi
    printf '%s' "$k"
}

_dash_row_line() {
    case "$1" in
        profile) printf '%s' "$LINE_PROFILE" ;;
        auth_mode) printf '%s' "$LINE_AUTH" ;;
        base_url) printf '%s' "$LINE_BASEURL" ;;
        api_key) printf '%s' "$LINE_APIKEY" ;;
        model) printf '%s' "$LINE_MODEL" ;;
        ssh_dir) printf '%s' "$LINE_SSH" ;;
        workdir) printf '%s' "$LINE_WORKDIR" ;;
        git_name) printf '%s' "$LINE_GITNAME" ;;
        git_email) printf '%s' "$LINE_GITEMAIL" ;;
        confirm) printf '%s' "$LINE_CONFIRM" ;;
    esac
}

# Rows that don't apply to the current state are skipped during navigation —
# e.g. Base URL/API Key/Model are meaningless once SSO is selected.
_dash_row_enabled() {
    case "$1" in
        base_url | api_key) [[ "$AUTH_MODE" == "apikey" ]] ;;
        model) [[ "$AUTH_MODE" == "apikey" && -n "$API_KEY" ]] ;;
        git_email) [[ -n "$GIT_USER_NAME" ]] ;;
        *) return 0 ;;
    esac
}

_dash_draw_status() {
    _dash_goto "$LINE_STATUS"
    _dash_clear_line
    if [[ -n "${1:-}" ]]; then
        printf '  %s' "$1"
    fi
    return 0
}

_dash_draw_row() {
    local id="$1" line label="" value="" selected=0 enabled=1
    line=$(_dash_row_line "$id")
    [[ -z "$line" ]] && return 0
    if [[ "$id" != "profile" && "${_DASH_ROW_IDS[$_DASH_SEL]}" == "$id" ]]; then
        selected=1
    fi
    _dash_row_enabled "$id" || enabled=0

    case "$id" in
        profile)
            local prof
            prof=$(cat "$REPO_DIR/.claude-profile" 2>/dev/null || echo "?")
            label="Profile"
            value="${_DASH_BOLD}${prof}${_DASH_RESET}   ${_DASH_DIM}(locked for this checkout)${_DASH_RESET}"
            ;;
        auth_mode)
            label="Auth Mode"
            value="${AUTH_MODE}   ${_DASH_DIM}[Enter: toggle sso/apikey]${_DASH_RESET}"
            ;;
        base_url)
            label="Base URL"
            if ((enabled)); then
                value="${BASE_URL:-<none>}   ${_DASH_DIM}[Enter: cycle]${_DASH_RESET}"
            else
                value="${_DASH_DIM}(not used for sso)${_DASH_RESET}"
            fi
            ;;
        api_key)
            label="API Key"
            if ((enabled)); then
                if [[ -n "$API_KEY" ]]; then
                    local mask
                    mask=$(printf '%*s' "${#API_KEY}" '' | tr ' ' '*')
                    value="${mask}   ${_DASH_GREEN}set${_DASH_RESET}"
                else
                    value="${_DASH_RED}(required — Enter to set)${_DASH_RESET}"
                fi
            else
                value="${_DASH_DIM}(not used for sso)${_DASH_RESET}"
            fi
            ;;
        model)
            label="Model"
            if ((enabled)); then
                if [[ ${#_DASH_FETCHED_MODELS[@]} -gt 0 ]]; then
                    value="${ANTHROPIC_MODEL}   ${_DASH_DIM}[Enter: cycle fetched models]${_DASH_RESET}"
                else
                    value="${ANTHROPIC_MODEL:-<none>}   ${_DASH_DIM}[Enter: edit]${_DASH_RESET}"
                fi
            elif [[ "$AUTH_MODE" == "sso" ]]; then
                value="${_DASH_DIM}(select inside Claude Code with /model)${_DASH_RESET}"
            else
                value="${_DASH_DIM}(enter API key first)${_DASH_RESET}"
            fi
            ;;
        ssh_dir)
            label="SSH Key Dir"
            value="${SSH_DIR:-(skip)}"
            ;;
        workdir)
            label="Default Workspace"
            value="${WORKDIR_INPUT:-\$PWD at runtime}"
            ;;
        git_name)
            label="Git user.name"
            value="${GIT_USER_NAME:-(skip)}"
            ;;
        git_email)
            label="Git user.email"
            if ((enabled)); then
                value="${GIT_USER_EMAIL:-(skip)}"
            else
                value="${_DASH_DIM}(set git user.name first)${_DASH_RESET}"
            fi
            ;;
        confirm)
            if [[ "$AUTH_MODE" == "apikey" && -z "$API_KEY" ]]; then
                value="${_DASH_YELLOW}▶ CONFIRM & LAUNCH${_DASH_RESET}  ${_DASH_DIM}(blocked — API key required above)${_DASH_RESET}"
            else
                value="${_DASH_GREEN}${_DASH_BOLD}▶ CONFIRM & LAUNCH${_DASH_RESET}"
            fi
            ;;
    esac

    _dash_goto "$line"
    _dash_clear_line
    local marker="  " lcol="$_DASH_RESET"
    if ((selected)); then
        marker="${_DASH_BOLD}${_DASH_CYAN}> ${_DASH_RESET}"
        lcol="${_DASH_BOLD}"
    fi
    if [[ -n "$label" ]]; then
        printf '%s%s%-18s%s %s' "$marker" "$lcol" "${label}:" "$_DASH_RESET" "$value"
    else
        printf '%s%s' "$marker" "$value"
    fi
}

_dash_full_redraw() {
    clear
    _dash_goto "$LINE_TITLE"
    printf '%s%s claude-sandbox — Setup Dashboard %s' "$_DASH_BOLD" "$_DASH_CYAN" "$_DASH_RESET"
    _dash_goto "$LINE_HINT"
    printf '%sUp/Down move    Enter edit or toggle selected row    q abort%s' "$_DASH_DIM" "$_DASH_RESET"
    _dash_draw_row profile
    local id
    for id in "${_DASH_ROW_IDS[@]}"; do
        _dash_draw_row "$id"
    done
    _dash_goto "$LINE_HELP"
    printf '%sRed = required and missing. Enter on CONFIRM writes .env and starts the image build.%s' "$_DASH_DIM" "$_DASH_RESET"
    _dash_draw_status ""
}

_dash_move() {
    local delta="$1" n=${#_DASH_ROW_IDS[@]} tries=0 new=$_DASH_SEL old=$_DASH_SEL
    while ((tries < n)); do
        new=$(((new + delta + n) % n))
        if _dash_row_enabled "${_DASH_ROW_IDS[$new]}"; then
            _DASH_SEL=$new
            _dash_draw_row "${_DASH_ROW_IDS[$old]}"
            _dash_draw_row "${_DASH_ROW_IDS[$new]}"
            _dash_draw_status ""
            return 0
        fi
        tries=$((tries + 1))
    done
}

_dash_edit_text() {
    local id="$1" label="$2"
    local -n _dash_val="$3"
    local line
    line=$(_dash_row_line "$id")
    _dash_cursor_show
    _dash_goto "$line"
    _dash_clear_line
    read -e -r -i "$_dash_val" -p "  ${label}: " _dash_val || true
    _dash_cursor_hide
}

_dash_edit_sshdir() {
    local line input
    line=$(_dash_row_line ssh_dir)
    _dash_cursor_show
    _dash_goto "$line"
    _dash_clear_line
    read -e -r -i "${SSH_DIR:-$HOME/.ssh}" -p "  SSH key directory ('skip' to omit mount): " input || true
    if [[ "${input,,}" == "skip" ]]; then
        SSH_DIR=""
    else
        SSH_DIR="${input:-$HOME/.ssh}"
    fi
    _dash_cursor_hide
}

_dash_fetch_models() {
    _DASH_FETCHED_MODELS=()
    _DASH_MODEL_IDX=0
    [[ -z "$BASE_URL" || -z "$API_KEY" ]] && return 0
    _dash_goto "$LINE_MODEL"
    _dash_clear_line
    printf '  Model: %sfetching from %s...%s' "$_DASH_DIM" "$BASE_URL" "$_DASH_RESET"
    local model
    while IFS= read -r model; do
        [[ -n "$model" ]] && _DASH_FETCHED_MODELS+=("$model")
    done < <(curl -sf "$BASE_URL/v1/models" \
        -H "Authorization: Bearer $API_KEY" 2>/dev/null |
        grep -oE '"id" *: *"claude[^"]*"' |
        grep -oE 'claude[^"]+' |
        sort -r)
    if [[ ${#_DASH_FETCHED_MODELS[@]} -gt 0 ]]; then
        local i=0 m
        for m in "${_DASH_FETCHED_MODELS[@]}"; do
            [[ "$m" == "claude-sonnet-5" ]] && _DASH_MODEL_IDX=$i
            i=$((i + 1))
        done
        ANTHROPIC_MODEL="${_DASH_FETCHED_MODELS[$_DASH_MODEL_IDX]}"
    else
        ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-sonnet-5}"
    fi
}

_dash_edit_apikey() {
    local line prompt input
    line=$(_dash_row_line api_key)
    _dash_cursor_show
    _dash_goto "$line"
    _dash_clear_line
    prompt="  API Key: "
    [[ -n "$API_KEY" ]] && prompt="  API Key (blank = keep current): "
    read -rs -p "$prompt" input || true
    echo ""
    if [[ -n "$input" ]]; then
        API_KEY="$input"
        # Reactive fetch: the model list depends on a working key, so pull it
        # the moment the key changes rather than as a separate prompt step.
        _dash_fetch_models
    fi
    _dash_cursor_hide
}

_dash_try_confirm() {
    if [[ "$AUTH_MODE" == "apikey" && -z "$API_KEY" ]]; then
        _dash_draw_status "${_DASH_RED}API key is required for apikey auth mode — select the API Key row and fill it in.${_DASH_RESET}"
        return 0
    fi
    _DASH_DONE=1
}

_dash_activate_row() {
    local id="$1"
    case "$id" in
        auth_mode)
            if [[ "$AUTH_MODE" == "apikey" ]]; then
                AUTH_MODE="sso"
            else
                AUTH_MODE="apikey"
                if [[ -z "$BASE_URL" ]]; then
                    _DASH_BASEURL_MODE="fuelix"
                    BASE_URL="https://api.fuelix.ai"
                fi
            fi
            return 0
            ;;
        base_url)
            case "$_DASH_BASEURL_MODE" in
                fuelix)
                    _DASH_BASEURL_MODE="anthropic"
                    BASE_URL="https://api.anthropic.com"
                    ;;
                anthropic)
                    _DASH_BASEURL_MODE="custom"
                    _dash_edit_text base_url "Base URL" BASE_URL
                    ;;
                *)
                    _DASH_BASEURL_MODE="fuelix"
                    BASE_URL="https://api.fuelix.ai"
                    ;;
            esac
            ;;
        api_key)
            _dash_edit_apikey
            ;;
        model)
            if [[ ${#_DASH_FETCHED_MODELS[@]} -gt 0 ]]; then
                _DASH_MODEL_IDX=$(((_DASH_MODEL_IDX + 1) % ${#_DASH_FETCHED_MODELS[@]}))
                ANTHROPIC_MODEL="${_DASH_FETCHED_MODELS[$_DASH_MODEL_IDX]}"
            else
                _dash_edit_text model "Model ID" ANTHROPIC_MODEL
            fi
            ;;
        ssh_dir)
            _dash_edit_sshdir
            ;;
        workdir)
            _dash_edit_text workdir "Default workspace" WORKDIR_INPUT
            ;;
        git_name)
            _dash_edit_text git_name "Git user.name" GIT_USER_NAME
            ;;
        git_email)
            _dash_edit_text git_email "Git user.email" GIT_USER_EMAIL
            ;;
        confirm)
            _dash_try_confirm
            ;;
    esac
}

# The real workhorse behind common_prompt_auth/common_prompt_mounts/
# common_prompt_git — see the block comment above. Runs once per setup.sh
# invocation no matter which of the three names is called first.
_common_ensure_dashboard() {
    [[ -n "${_COMMON_DASHBOARD_DONE:-}" ]] && return 0
    _COMMON_DASHBOARD_DONE=1

    AUTH_MODE="${AUTH_MODE:-apikey}"
    _DASH_BASEURL_MODE="fuelix"
    BASE_URL="${BASE_URL:-https://api.fuelix.ai}"
    case "$BASE_URL" in
        https://api.fuelix.ai) _DASH_BASEURL_MODE="fuelix" ;;
        https://api.anthropic.com) _DASH_BASEURL_MODE="anthropic" ;;
        *) _DASH_BASEURL_MODE="custom" ;;
    esac
    API_KEY="${API_KEY:-}"
    ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-}"
    _DASH_FETCHED_MODELS=()
    _DASH_MODEL_IDX=0

    SSH_DIR="${SSH_DIR:-$HOME/.ssh}"
    WORKDIR_INPUT="${WORKDIR_INPUT:-}"

    local host_name host_email
    host_name=$(git config --global user.name 2>/dev/null || echo "")
    host_email=$(git config --global user.email 2>/dev/null || echo "")
    GIT_USER_NAME="${GIT_USER_NAME:-$host_name}"
    GIT_USER_EMAIL="${GIT_USER_EMAIL:-$host_email}"

    _dash_colors
    _dash_layout
    _DASH_ROW_IDS=(auth_mode base_url api_key model ssh_dir workdir git_name git_email confirm)
    _DASH_SEL=0
    local guard=0
    while ! _dash_row_enabled "${_DASH_ROW_IDS[$_DASH_SEL]}" && ((guard < ${#_DASH_ROW_IDS[@]})); do
        _DASH_SEL=$(((_DASH_SEL + 1) % ${#_DASH_ROW_IDS[@]}))
        guard=$((guard + 1))
    done

    _dash_cursor_hide
    _DASH_DONE=""
    _dash_full_redraw
    local key
    while [[ -z "$_DASH_DONE" ]]; do
        key=$(_dash_read_key)
        case "$key" in
            UP) _dash_move -1 ;;
            DOWN) _dash_move 1 ;;
            ENTER)
                _dash_activate_row "${_DASH_ROW_IDS[$_DASH_SEL]}"
                _dash_full_redraw
                ;;
            q | Q)
                _dash_cursor_show
                _dash_goto "$DASH_TOTAL_LINES"
                echo ""
                echo "Setup aborted — no changes written."
                exit 1
                ;;
            *) : ;;
        esac
    done

    _dash_cursor_show
    _dash_goto "$DASH_TOTAL_LINES"
    echo ""
    echo "${_DASH_GREEN}Configuration confirmed.${_DASH_RESET}"
}

common_prompt_auth() { _common_ensure_dashboard; }
common_prompt_mounts() { _common_ensure_dashboard; }
common_prompt_git() { _common_ensure_dashboard; }

common_write_env() {
    cat >"$ENV_FILE" <<EOF
# Auth
DEFAULT_AUTH=${AUTH_MODE}
ANTHROPIC_API_KEY=${API_KEY}
ANTHROPIC_BASE_URL=${BASE_URL}
ANTHROPIC_MODEL=${ANTHROPIC_MODEL}

# Mounts
SSH_DIR=${SSH_DIR}
CLAUDE_WORKDIR=${WORKDIR_INPUT}

# Container user (captured at setup — matches host uid/gid for correct file ownership)
CONTAINER_USER=${CONTAINER_USER}
CONTAINER_UID=${CONTAINER_UID}
CONTAINER_GID=${CONTAINER_GID}
EOF
    echo ""
    echo ".env written to $ENV_FILE"
}

common_build_image() {
    echo ""
    echo "Building Docker image..."
    docker compose -f "$PROFILE_DIR/docker-compose.yml" build \
        --build-arg DOCKER_GID="${DOCKER_GID:-984}" \
        --build-arg USERNAME="$CONTAINER_USER" \
        --build-arg USER_UID="$CONTAINER_UID" \
        --build-arg USER_GID="$CONTAINER_GID"
    echo "Build complete."
}

common_seed_home() {
    echo ""
    echo "Seeding .home/.claude/..."
    mkdir -p "$HOME_DIR/.claude"

    if [[ -n "${GIT_USER_NAME:-}" && -n "${GIT_USER_EMAIL:-}" ]]; then
        cat >"$HOME_DIR/.gitconfig" <<EOF
[user]
    name = $GIT_USER_NAME
    email = $GIT_USER_EMAIL
EOF
        echo "  .gitconfig seeded ($GIT_USER_NAME <$GIT_USER_EMAIL>)."
    fi
}

common_seed_gh_skill() {
    local skill_dir="$HOME_DIR/.claude/skills/gh-login"
    mkdir -p "$skill_dir"
    cat >"$skill_dir/SKILL.md" <<'SKILL'
---
description: Authenticate the gh CLI via OAuth device flow, for git push/PR/issue operations from inside the container.
disable-model-invocation: true
---

Authenticate `gh` (the GitHub CLI) for this container via OAuth device flow.

1. Run `gh auth status`. If it already reports an authenticated account, tell the user and stop.
2. Otherwise, run (via the Bash tool, with a long timeout — this blocks until the user completes
   auth in their browser or it times out):
   ```
   printf '\n' | gh auth login --hostname github.com --git-protocol https --web
   ```
   `BROWSER=echo` is set in this container, so `gh` won't try to launch a browser itself — it
   prints a one-time code and a `https://github.com/login/device` URL instead of opening one.
3. As soon as the code and URL appear in the command's output, relay them to the user verbatim and
   tell them to open the URL on their own machine (not inside the container) and enter the code.
4. Wait for the command to finish. On success, confirm with `gh auth status` and report the
   authenticated account back to the user.

Auth state is written to `.home/.config/gh/` on the host, which is bind-mounted as this container's
home directory — it persists across container restarts, the same way OAuth state for `sso` auth
mode persists in `.home/.claude.json`.
SKILL
    echo "  gh-login skill seeded."
}
