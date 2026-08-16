#!/bin/bash
# Sourced by each profile's setup.sh — do not run directly.
# Caller must set: REPO_DIR, PROFILE_DIR, ENV_FILE, HOME_DIR
#
# UX direction: "Minimal Table" (candidate A for #45 / #46) — restrained color,
# no box-drawing panels. The bulk of the interactive work happens in a single
# arrow-key-navigable defaults table (see common_prompt_auth, which renders it
# and also absorbs common_prompt_mounts/common_prompt_git's prompting so the
# whole set of defaults lives on one screen). Function names and call order
# are unchanged from before this redesign — see CLAUDE.md's variable contract.

# ---------------------------------------------------------------------------
# Small UI toolkit: colors + a raw single-keypress reader. Pure tput/ANSI,
# no new binary.
# ---------------------------------------------------------------------------

_ui_init_colors() {
    # Idempotent — safe to call multiple times.
    if [[ -t 1 ]]; then
        C_BOLD=$(tput bold 2>/dev/null || echo "")
        C_DIM=$(tput dim 2>/dev/null || echo "")
        C_CYAN=$(tput setaf 6 2>/dev/null || echo "")
        C_RED=$(tput setaf 1 2>/dev/null || echo "")
        C_GREEN=$(tput setaf 2 2>/dev/null || echo "")
        C_RESET=$(tput sgr0 2>/dev/null || echo "")
    else
        C_BOLD=""
        C_DIM=""
        C_CYAN=""
        C_RED=""
        C_GREEN=""
        C_RESET=""
    fi
}

# Reads one logical key press from the terminal and prints a token:
# UP / DOWN / ENTER / CHAR:<c> — arrow keys arrive as 3-byte escape
# sequences, everything else is a single byte.
_ui_read_key() {
    local k rest
    IFS= read -rsn1 k || true
    if [[ "$k" == $'\x1b' ]]; then
        IFS= read -rsn2 -t 0.05 rest || true
        case "$rest" in
            '[A') printf 'UP' ;;
            '[B') printf 'DOWN' ;;
            *) printf 'ESC' ;;
        esac
    elif [[ -z "$k" ]]; then
        printf 'ENTER'
    else
        printf 'CHAR:%s' "$k"
    fi
}

_ui_mask() {
    local s="$1"
    printf '%*s' "${#s}" '' | tr ' ' '*'
}

common_detect_os() {
    _ui_init_colors

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
    esac

    CONTAINER_USER=$(id -un)
    CONTAINER_UID=$(id -u)
    CONTAINER_GID=$(id -g)

    echo "${C_DIM}Detected: ${OS}${DOCKER_GID:+, docker gid ${DOCKER_GID}}, user ${CONTAINER_USER} (${CONTAINER_UID}:${CONTAINER_GID})${C_RESET}"
    echo ""
}

# ---------------------------------------------------------------------------
# The defaults table. Every field that used to be its own "press Enter to
# accept" prompt lives here on one screen: auth mode, base URL, API key, SSH
# key dir, workspace dir, git identity. Up/Down move, Enter edits/toggles the
# selected row, Enter on "Continue" validates and confirms.
#
# Row indices (kept in three parallel arrays so ordering is guaranteed):
#   0 auth mode   1 base URL   2 API key   3 SSH dir   4 workdir
#   5 git name    6 git email  7 (pseudo) confirm action
# ---------------------------------------------------------------------------

_tbl_row_active() {
    # Base URL and API key rows are only meaningful in apikey mode; dim them
    # rather than hide them so the table's line count never shifts.
    local idx=$1
    case "${ROW_KIND[$idx]}" in
        baseurl | secret) [[ "${ROW_VALUE[0]}" == "apikey" ]] ;;
        *) return 0 ;;
    esac
}

_tbl_is_selectable() {
    local idx=$1
    [[ $idx -eq $CONFIRM_ROW ]] && return 0
    _tbl_row_active "$idx"
}

_tbl_move() {
    # $1: current index, $2: +1 or -1. Wraps, skipping inactive rows.
    local idx=$1 dir=$2 i=$1 steps=0
    while ((steps <= CONFIRM_ROW)); do
        i=$(((i + dir + CONFIRM_ROW + 1) % (CONFIRM_ROW + 1)))
        _tbl_is_selectable "$i" && {
            printf '%s' "$i"
            return
        }
        ((steps++))
    done
    printf '%s' "$idx"
}

_tbl_display_value() {
    local idx=$1
    case "${ROW_KIND[$idx]}" in
        auth)
            printf '%s' "${ROW_VALUE[$idx]}"
            ;;
        baseurl)
            if [[ "${ROW_VALUE[0]}" != "apikey" ]]; then
                printf '(not used for SSO)'
            elif [[ -z "${ROW_VALUE[$idx]}" ]]; then
                printf '(blank)'
            else
                printf '%s' "${ROW_VALUE[$idx]}"
            fi
            ;;
        secret)
            if [[ "${ROW_VALUE[0]}" != "apikey" ]]; then
                printf '(not used for SSO)'
            elif [[ -z "${ROW_VALUE[$idx]}" ]]; then
                printf '%s(required — Enter to set)%s' "$C_RED" "$C_RESET"
            else
                _ui_mask "${ROW_VALUE[$idx]}"
            fi
            ;;
        text)
            if [[ -z "${ROW_VALUE[$idx]}" ]]; then
                printf '(none)'
            else
                printf '%s' "${ROW_VALUE[$idx]}"
            fi
            ;;
    esac
}

_tbl_draw() {
    local i line marker label_col active
    tput cup 0 0
    tput el
    printf '%sSetup defaults%s  %s(Up/Down move, Enter edit/toggle, Enter on Continue to confirm)%s\n' \
        "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
    tput cup 1 0
    tput el
    printf '\n'
    for ((i = 0; i <= CONFIRM_ROW; i++)); do
        tput cup $((i + 2)) 0
        tput el
        marker="  "
        [[ $i -eq $cur ]] && marker="${C_CYAN}> ${C_RESET}"
        if [[ $i -eq $CONFIRM_ROW ]]; then
            if [[ $i -eq $cur ]]; then
                printf '%s%s%s[ Continue ]%s\n' "$marker" "$C_BOLD" "$C_GREEN" "$C_RESET"
            else
                printf '%s%s[ Continue ]%s\n' "$marker" "$C_GREEN" "$C_RESET"
            fi
            continue
        fi
        active=1
        _tbl_row_active "$i" || active=0
        label_col=""
        [[ $active -eq 0 ]] && label_col="$C_DIM"
        [[ $i -eq $cur ]] && label_col="$C_BOLD"
        line="$(_tbl_display_value "$i")"
        printf '%s%s%-15s%s %s\n' "$marker" "$label_col" "${ROW_LABEL[$i]}:" "$C_RESET" "$line"
    done
    tput cup $((CONFIRM_ROW + 3)) 0
    tput el
    printf '\n'
    tput cup $((CONFIRM_ROW + 4)) 0
    tput el
    if [[ -n "$error_msg" ]]; then
        printf '%s%s%s\n' "$C_RED" "$error_msg" "$C_RESET"
    else
        printf '\n'
    fi
}

# Reads one line of input at the row just below the table, in cooked mode
# (read -e), then hands control back to the raw single-key loop.
_tbl_edit_row() {
    local idx=$1 input_row=$((CONFIRM_ROW + 5))
    tput cup "$input_row" 0
    tput el
    case "${ROW_KIND[$idx]}" in
        auth)
            if [[ "${ROW_VALUE[0]}" == "apikey" ]]; then
                ROW_VALUE[0]="sso"
            else
                ROW_VALUE[0]="apikey"
            fi
            ;;
        baseurl)
            _tbl_row_active "$idx" || return 0
            case "${ROW_VALUE[$idx]}" in
                "https://api.fuelix.ai") ROW_VALUE[idx]="https://api.anthropic.com" ;;
                "https://api.anthropic.com")
                    local custom_url=""
                    read -rep "  Custom base URL (blank to clear): " custom_url
                    ROW_VALUE[idx]="$custom_url"
                    ;;
                *) ROW_VALUE[idx]="https://api.fuelix.ai" ;;
            esac
            ;;
        secret)
            _tbl_row_active "$idx" || return 0
            local new_key=""
            read -rsp "  API key (input hidden): " new_key
            printf '\n'
            ROW_VALUE[idx]="$new_key"
            ;;
        text)
            local new_val
            read -rep "  ${ROW_LABEL[$idx]} [${ROW_VALUE[$idx]}]: " -i "${ROW_VALUE[$idx]}" new_val
            ROW_VALUE[idx]="$new_val"
            ;;
    esac
}

_tbl_validate() {
    if [[ "${ROW_VALUE[0]}" == "apikey" && -z "${ROW_VALUE[2]}" ]]; then
        printf 'API key is required for apikey auth mode — select it and press Enter to set.'
    fi
}

common_prompt_auth() {
    _ui_init_colors

    local host_git_name host_git_email
    host_git_name=$(git config --global user.name 2>/dev/null || echo "")
    host_git_email=$(git config --global user.email 2>/dev/null || echo "")

    local -a ROW_LABEL=(
        "Auth mode" "Base URL" "API key" "SSH key dir" "Workspace dir"
        "Git name" "Git email"
    )
    local -a ROW_KIND=(auth baseurl secret text text text text)
    local -a ROW_VALUE=(
        "apikey" "https://api.fuelix.ai" "" "$HOME/.ssh" ""
        "$host_git_name" "$host_git_email"
    )
    local -i n_field_rows=$((${#ROW_LABEL[@]} - 1))
    local -i CONFIRM_ROW=$((n_field_rows + 1))
    local -i cur=0
    local error_msg=""
    local key

    tput civis 2>/dev/null || true
    tput smcup
    _tbl_draw
    while true; do
        key=$(_ui_read_key)
        case "$key" in
            UP) cur=$(_tbl_move "$cur" -1) ;;
            DOWN) cur=$(_tbl_move "$cur" 1) ;;
            ENTER)
                if [[ $cur -eq $CONFIRM_ROW ]]; then
                    error_msg="$(_tbl_validate)"
                    [[ -z "$error_msg" ]] && break
                else
                    _tbl_edit_row "$cur"
                    error_msg=""
                fi
                ;;
            *) : ;;
        esac
        _tbl_draw
    done
    tput rmcup
    tput cnorm 2>/dev/null || true

    AUTH_MODE="${ROW_VALUE[0]}"
    BASE_URL="${ROW_VALUE[1]}"
    API_KEY="${ROW_VALUE[2]}"
    if [[ "${ROW_VALUE[3],,}" == "skip" ]]; then
        SSH_DIR=""
    else
        SSH_DIR="${ROW_VALUE[3]:-$HOME/.ssh}"
    fi
    WORKDIR_INPUT="${ROW_VALUE[4]}"
    GIT_USER_NAME="${ROW_VALUE[5]}"
    GIT_USER_EMAIL="${ROW_VALUE[6]}"
    [[ -z "$GIT_USER_NAME" ]] && GIT_USER_EMAIL=""

    echo "${C_BOLD}Defaults confirmed.${C_RESET}"
    echo ""

    ANTHROPIC_MODEL=""
    if [[ "$AUTH_MODE" == "apikey" && -n "$BASE_URL" && -n "$API_KEY" ]]; then
        echo "${C_BOLD}Model${C_RESET}"
        echo "Fetching available Claude models from $BASE_URL..."
        local -a CLAUDE_MODELS=()
        while IFS= read -r model; do
            [[ -n "$model" ]] && CLAUDE_MODELS+=("$model")
        done < <(curl -sf "$BASE_URL/v1/models" \
            -H "Authorization: Bearer $API_KEY" 2>/dev/null |
            grep -oE '"id" *: *"claude[^"]*"' |
            grep -oE 'claude[^"]+' |
            sort -r)

        if [[ ${#CLAUDE_MODELS[@]} -gt 0 ]]; then
            local default_idx=1 i=1 m label
            for m in "${CLAUDE_MODELS[@]}"; do
                label="  $i) $m"
                if [[ "$m" == "claude-sonnet-5" ]]; then
                    label+=" ${C_GREEN}(recommended)${C_RESET}"
                    default_idx=$i
                fi
                echo "$label"
                ((i++))
            done
            echo ""
            local model_choice
            read -rp "Select model [${default_idx}]: " model_choice
            model_choice="${model_choice:-$default_idx}"
            if [[ "$model_choice" =~ ^[0-9]+$ && "$model_choice" -ge 1 && "$model_choice" -le "${#CLAUDE_MODELS[@]}" ]]; then
                ANTHROPIC_MODEL="${CLAUDE_MODELS[$((model_choice - 1))]}"
                echo "Selected: $ANTHROPIC_MODEL"
            fi
        else
            echo "${C_DIM}Could not fetch model list — enter model ID manually.${C_RESET}"
            read -rep "  ANTHROPIC_MODEL [claude-sonnet-5]: " ANTHROPIC_MODEL
            ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-sonnet-5}"
        fi
        echo ""
    elif [[ "$AUTH_MODE" == "sso" ]]; then
        echo "${C_DIM}SSO: select your model inside Claude Code with /model${C_RESET}"
        echo ""
    fi
}

# Mounts and git identity are already gathered by the defaults table above —
# these stay as their own call points (contract: function names + call order
# unchanged) but just confirm the values rather than re-prompting.
common_prompt_mounts() {
    : "${SSH_DIR:=}"
    : "${WORKDIR_INPUT:=}"
    echo "${C_DIM}Mounts: SSH ${SSH_DIR:-(skipped)}, workspace ${WORKDIR_INPUT:-\$PWD at runtime}${C_RESET}"
}

common_prompt_git() {
    : "${GIT_USER_NAME:=}"
    : "${GIT_USER_EMAIL:=}"
    if [[ -n "$GIT_USER_NAME" ]]; then
        echo "${C_DIM}Git identity: $GIT_USER_NAME <$GIT_USER_EMAIL>${C_RESET}"
    else
        echo "${C_DIM}Git identity: (not set)${C_RESET}"
    fi
}

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
