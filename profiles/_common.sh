#!/bin/bash
# Sourced by each profile's setup.sh — do not run directly.
# Caller must set: REPO_DIR, PROFILE_DIR, ENV_FILE, HOME_DIR
#
# claude.sh's init() also sources this file, but only for the ui_* toolkit
# below — the common_* setup functions further down require REPO_DIR/
# PROFILE_DIR/ENV_FILE/HOME_DIR and are not meant to be called from there.

# ---------------------------------------------------------------------------
# Boxed-wizard UI toolkit — box-drawing panels + single-key default-accept.
# Pure bash + tput/ANSI escapes, no new host dependency. Degrades to plain
# text automatically when tput or a real terminal isn't available.
# ---------------------------------------------------------------------------

UI_WIDTH=68

ui_init() {
    UI_BOLD="" UI_DIM="" UI_CYAN="" UI_GREEN="" UI_YELLOW="" UI_RESET=""
    if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
        local colors
        colors="$(tput colors 2>/dev/null || echo 0)"
        if [[ "$colors" =~ ^[0-9]+$ ]] && ((colors >= 8)); then
            UI_BOLD="$(tput bold 2>/dev/null || true)"
            UI_DIM="$(tput dim 2>/dev/null || true)"
            UI_CYAN="$(tput setaf 6 2>/dev/null || true)"
            UI_GREEN="$(tput setaf 2 2>/dev/null || true)"
            UI_YELLOW="$(tput setaf 3 2>/dev/null || true)"
            UI_RESET="$(tput sgr0 2>/dev/null || true)"
        fi
        local cols
        cols="$(tput cols 2>/dev/null || echo 80)"
        if [[ "$cols" =~ ^[0-9]+$ ]] && ((cols - 4 < UI_WIDTH)); then
            UI_WIDTH=$((cols - 4))
            ((UI_WIDTH < 44)) && UI_WIDTH=44
        fi
    fi
}

# Repeats a single character UI_WIDTH times (used for box borders/dividers).
# Built via plain string concatenation, not `tr` — `tr` mangles multi-byte
# UTF-8 box-drawing characters under a non-UTF-8 locale (e.g. C/POSIX).
ui_hline() {
    local ch="${1:--}" line="" i
    for ((i = 0; i < UI_WIDTH; i++)); do
        line+="$ch"
    done
    printf '%s' "$line"
}

ui_box_top() {
    printf '%s┌%s┐%s\n' "$UI_CYAN" "$(ui_hline ─)" "$UI_RESET"
}

ui_box_bottom() {
    printf '%s└%s┘%s\n' "$UI_CYAN" "$(ui_hline ─)" "$UI_RESET"
}

ui_box_div() {
    printf '%s├%s┤%s\n' "$UI_CYAN" "$(ui_hline ─)" "$UI_RESET"
}

# ui_box_line <plain text> [<styled text>]
# Padding is always computed from the plain text so ANSI color codes in the
# (optional) styled variant never throw off column alignment. Dynamic content
# (a long path, URL, or git identity) is truncated with "..." so the right
# border always stays put, no matter how long the underlying value is.
ui_box_line() {
    local plain="${1:-}"
    local styled="${2:-$plain}"
    local field=$((UI_WIDTH - 2))
    if ((${#plain} > field)); then
        local cut=$((field - 3))
        ((cut < 0)) && cut=0
        plain="${plain:0:cut}..."
        styled="$plain"
    fi
    local pad=$((field - ${#plain}))
    ((pad < 0)) && pad=0
    printf '%s│%s %s%*s %s│%s\n' "$UI_CYAN" "$UI_RESET" "$styled" "$pad" "" "$UI_CYAN" "$UI_RESET"
}

# ui_screen <title> [info line]...
# Opens a titled box (used as each wizard screen's header/summary panel).
# Any interactive prompts belong below the box, as plain reads — a border
# can't safely contain live keyboard input without fragile cursor tricks.
ui_screen() {
    local title="$1"
    shift
    echo ""
    ui_box_top
    ui_box_line "$title" "${UI_BOLD}${UI_CYAN}${title}${UI_RESET}"
    if (($# > 0)); then
        ui_box_div
        local line
        for line in "$@"; do
            ui_box_line "$line"
        done
    fi
    ui_box_bottom
    echo ""
}

ui_info() { printf '  %s%s%s\n' "$UI_DIM" "$1" "$UI_RESET"; }
ui_ok() { printf '  %s✓ %s%s\n' "$UI_GREEN" "$1" "$UI_RESET"; }
ui_warn() { printf '  %s! %s%s\n' "$UI_YELLOW" "$1" "$UI_RESET"; }

ui_mask() {
    local s="$1"
    printf '%*s' "${#s}" '' | tr ' ' '*'
}

# ui_ask <label> <default value> [<default display>]
# Single-key default-accept: pressing Enter accepts <default value>
# immediately. Pressing any other key opens a normal editable prompt
# (readline-seeded with that key on a real terminal) for a full answer.
# Sets UI_VALUE.
ui_ask() {
    local label="$1" default="$2" display="${3:-$2}"
    [[ -z "$display" ]] && display="(none)"
    printf '%s%s%s %s[%s]%s (Enter=accept, or type to change): ' \
        "$UI_BOLD" "$label" "$UI_RESET" "$UI_DIM" "$display" "$UI_RESET"
    local key="" value
    IFS= read -rsn1 key || true
    if [[ -z "$key" ]]; then
        printf '%s\n' "${UI_GREEN}${display}${UI_RESET}"
        UI_VALUE="$default"
        return 0
    fi
    read -rei "$key" -p '' value || true
    UI_VALUE="${value:-$default}"
}

# ui_confirm <label> <y|n default> — single keypress yes/no. Returns 0/1.
ui_confirm() {
    local label="$1" default="${2:-y}" key hint
    [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
    printf '%s%s%s [%s] ' "$UI_BOLD" "$label" "$UI_RESET" "$hint"
    key=""
    IFS= read -rsn1 key || true
    echo "$key"
    key="${key,,}"
    [[ -z "$key" ]] && key="$default"
    [[ "$key" == "y" ]]
}

# ui_secret <label> — loops until non-empty. No default; used where a blank
# value must never be accepted (e.g. a required API key). Sets UI_VALUE.
ui_secret() {
    local label="$1" value
    while true; do
        read -rsp "${UI_BOLD}${label}${UI_RESET}: " value || true
        echo ""
        if [[ -n "$value" ]]; then
            UI_VALUE="$value"
            return 0
        fi
        ui_warn "Required — this can't be blank."
    done
}

# ---------------------------------------------------------------------------
# Setup steps — called in order by every profiles/*/setup.sh.
# ---------------------------------------------------------------------------

common_detect_os() {
    ui_init

    OS="linux"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        OS="macos"
    elif grep -qi microsoft /proc/version 2>/dev/null; then
        OS="wsl"
    fi

    DOCKER_GID=""
    case "$OS" in
        linux | wsl)
            DOCKER_GID=$(getent group docker | cut -d: -f3 2>/dev/null || echo "984")
            ;;
        macos) ;;
    esac

    CONTAINER_USER=$(id -un)
    CONTAINER_UID=$(id -u)
    CONTAINER_GID=$(id -g)

    ui_info "Detected OS: $OS"
    if [[ -n "$DOCKER_GID" ]]; then
        ui_info "Docker GID: $DOCKER_GID"
    elif [[ "$OS" == "macos" ]]; then
        ui_info "macOS: Docker Desktop handles socket permissions — no GID needed."
    fi
}

common_prompt_auth() {
    ui_screen "Step 2/5 - Auth" \
        "Configure how Claude Code authenticates with Anthropic." \
        "" \
        "1) apikey - gateway/API key auth (default)" \
        "2) sso    - OAuth via claude.ai"

    ui_ask "Auth mode" "1"
    case "$UI_VALUE" in
        2 | sso | SSO) AUTH_MODE="sso" ;;
        1 | apikey | APIKEY | "") AUTH_MODE="apikey" ;;
        *)
            ui_warn "Unrecognized choice '$UI_VALUE' — defaulting to apikey."
            AUTH_MODE="apikey"
            ;;
    esac
    ui_ok "Auth mode: $AUTH_MODE"

    ui_box_top
    ui_box_line "ANTHROPIC_BASE_URL"
    ui_box_div
    ui_box_line "1) https://api.fuelix.ai (default)"
    ui_box_line "2) https://api.anthropic.com"
    ui_box_line "3) Other / skip"
    ui_box_bottom
    ui_ask "Base URL choice" "1"
    case "$UI_VALUE" in
        1 | "") BASE_URL="https://api.fuelix.ai" ;;
        2) BASE_URL="https://api.anthropic.com" ;;
        3)
            ui_ask "Enter URL" "" "blank = skip"
            BASE_URL="$UI_VALUE"
            ;;
        *) BASE_URL="https://api.fuelix.ai" ;;
    esac
    echo ""

    # apikey mode: the key is REQUIRED — no skipping into a broken .env.
    # sso mode: unchanged, still optional (some gateways still want a key).
    API_KEY=""
    if [[ "$AUTH_MODE" == "apikey" ]]; then
        ui_secret "ANTHROPIC_API_KEY (required for apikey auth)"
        API_KEY="$UI_VALUE"
    elif [[ -n "$BASE_URL" ]]; then
        read -rsp "ANTHROPIC_API_KEY (press Enter to skip): " API_KEY || true
        echo ""
    fi

    ANTHROPIC_MODEL=""
    if [[ -n "$BASE_URL" && -n "$API_KEY" ]]; then
        ui_info "Fetching available Claude models from $BASE_URL..."
        CLAUDE_MODELS=()
        while IFS= read -r model; do
            [[ -n "$model" ]] && CLAUDE_MODELS+=("$model")
        done < <(curl -sf "$BASE_URL/v1/models" \
            -H "Authorization: Bearer $API_KEY" 2>/dev/null |
            grep -oE '"id" *: *"claude[^"]*"' |
            grep -oE 'claude[^"]+' |
            sort -r)

        if [[ ${#CLAUDE_MODELS[@]} -gt 0 ]]; then
            local default_idx=1 i=1 m label
            local model_lines=()
            for m in "${CLAUDE_MODELS[@]}"; do
                label="$i) $m"
                if [[ "$m" == "claude-sonnet-5" ]]; then
                    label+=" (recommended)"
                    default_idx=$i
                fi
                model_lines+=("$label")
                ((i++))
            done
            ui_screen "Auth - Model" "${model_lines[@]}"
            ui_ask "Select model" "$default_idx"
            if [[ "$UI_VALUE" =~ ^[0-9]+$ && "$UI_VALUE" -ge 1 && "$UI_VALUE" -le "${#CLAUDE_MODELS[@]}" ]]; then
                ANTHROPIC_MODEL="${CLAUDE_MODELS[$((UI_VALUE - 1))]}"
            else
                ANTHROPIC_MODEL="${CLAUDE_MODELS[$((default_idx - 1))]}"
            fi
            ui_ok "Selected: $ANTHROPIC_MODEL"
        else
            ui_warn "Could not fetch model list — enter model ID manually."
            ui_ask "ANTHROPIC_MODEL" "claude-sonnet-5"
            ANTHROPIC_MODEL="$UI_VALUE"
        fi
    elif [[ "$AUTH_MODE" == "sso" ]]; then
        ui_info "SSO: select your model inside Claude Code with /model"
    fi
}

common_prompt_mounts() {
    ui_screen "Step 3/5 - Mounts" \
        "Host directories to bind-mount into the container." \
        "" \
        "SSH keys  - for git push/pull over SSH from inside the container." \
        "Workspace - default working dir; blank = \$PWD at runtime."

    ui_ask "SSH key directory (or 'skip')" "$HOME/.ssh"
    if [[ "${UI_VALUE,,}" == "skip" ]]; then
        SSH_DIR=""
    else
        SSH_DIR="$UI_VALUE"
    fi
    ui_ok "SSH: ${SSH_DIR:-(skipped)}"

    ui_ask "Default workspace directory" "" "\$PWD at runtime"
    WORKDIR_INPUT="$UI_VALUE"
    ui_ok "Workspace: ${WORKDIR_INPUT:-\$PWD at runtime}"
}

common_prompt_git() {
    local host_name host_email
    host_name=$(git config --global user.name 2>/dev/null || echo "")
    host_email=$(git config --global user.email 2>/dev/null || echo "")

    ui_screen "Step 4/5 - Git" \
        "Git identity used for commits made inside the container."

    if [[ -n "$host_name" && -n "$host_email" ]]; then
        ui_box_top
        ui_box_line "Detected from host git config:"
        ui_box_line "  $host_name <$host_email>"
        ui_box_bottom
        if ui_confirm "Use this identity?" "y"; then
            GIT_USER_NAME="$host_name"
            GIT_USER_EMAIL="$host_email"
            ui_ok "Git identity: $GIT_USER_NAME <$GIT_USER_EMAIL>"
            return
        fi
    fi

    ui_ask "Git user.name (blank to skip)" "$host_name" "${host_name:-none}"
    GIT_USER_NAME="$UI_VALUE"

    if [[ -n "$GIT_USER_NAME" ]]; then
        ui_ask "Git user.email" "$host_email" "${host_email:-none}"
        GIT_USER_EMAIL="$UI_VALUE"
    else
        GIT_USER_EMAIL=""
    fi
    ui_ok "Git identity: ${GIT_USER_NAME:-(not set)}${GIT_USER_EMAIL:+ <$GIT_USER_EMAIL>}"
}

common_write_env() {
    local model_display="${ANTHROPIC_MODEL:-(gateway default)}"
    local key_display="(not set)"
    [[ -n "$API_KEY" ]] && key_display="$(ui_mask "$API_KEY")"

    ui_screen "Step 5/5 - Confirm" "Review before writing .env - this is the last step."

    ui_box_top
    ui_box_line "$(printf '%-14s %s' "Auth mode:" "$AUTH_MODE")"
    ui_box_line "$(printf '%-14s %s' "Base URL:" "${BASE_URL:-(unset)}")"
    ui_box_line "$(printf '%-14s %s' "API key:" "$key_display")"
    ui_box_line "$(printf '%-14s %s' "Model:" "$model_display")"
    ui_box_line "$(printf '%-14s %s' "SSH dir:" "${SSH_DIR:-(skipped)}")"
    ui_box_line "$(printf '%-14s %s' "Workspace:" "${WORKDIR_INPUT:-\$PWD at runtime}")"
    ui_box_line "$(printf '%-14s %s' "Git identity:" "${GIT_USER_NAME:-(not set)}${GIT_USER_EMAIL:+ <$GIT_USER_EMAIL>}")"
    ui_box_bottom

    if ! ui_confirm "Write this configuration to .env?" "y"; then
        echo ""
        ui_warn "Cancelled — no changes written. Re-run setup to try again."
        exit 1
    fi

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
    ui_ok ".env written to $ENV_FILE"
}

common_build_image() {
    echo ""
    ui_info "Building Docker image..."
    docker compose -f "$PROFILE_DIR/docker-compose.yml" build \
        --build-arg DOCKER_GID="${DOCKER_GID:-984}" \
        --build-arg USERNAME="$CONTAINER_USER" \
        --build-arg USER_UID="$CONTAINER_UID" \
        --build-arg USER_GID="$CONTAINER_GID"
    ui_ok "Build complete."
}

common_seed_home() {
    echo ""
    ui_info "Seeding .home/.claude/..."
    mkdir -p "$HOME_DIR/.claude"

    if [[ -n "${GIT_USER_NAME:-}" && -n "${GIT_USER_EMAIL:-}" ]]; then
        cat >"$HOME_DIR/.gitconfig" <<EOF
[user]
    name = $GIT_USER_NAME
    email = $GIT_USER_EMAIL
EOF
        ui_ok ".gitconfig seeded ($GIT_USER_NAME <$GIT_USER_EMAIL>)."
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
    ui_ok "gh-login skill seeded."
}
