#!/bin/bash
# Sourced by each profile's setup.sh — do not run directly.
# Caller must set: REPO_DIR, PROFILE_DIR, ENV_FILE, HOME_DIR
#
# claude.sh's init() also sources this file, but only for the ui_*/box/alt-screen
# toolkit below — the common_* setup functions further down need REPO_DIR/
# PROFILE_DIR/ENV_FILE/HOME_DIR and are not meant to be called from there.
#
# Final synthesis of the three setup-flow UX candidates (#46/#50, #47/#51,
# #48/#52 — see #45/#49): direction C's single arrow-key-navigable dashboard
# (one screen, all fields, reactive model fetch, CONFIRM blocked until an
# apikey-mode API key is set) drawn inside direction B's box-drawing frame
# (fixed: blue not cyan, ~120-col target instead of a hard 68-col truncating
# box, wrapping instead of clipping), wrapped in direction A's alternate-
# screen technique (fixed: scoped to skip the docker build log, and made
# crash/Ctrl-C safe via a trap). Function names and call order below are
# unchanged from before this redesign — see CLAUDE.md's variable contract.

# ---------------------------------------------------------------------------
# UI toolkit: colors, dynamic box width, box-drawing primitives that can
# safely wrap long content, an alternate-screen helper with a restore trap,
# and a raw single-keypress reader. Pure tput/ANSI + sed (already used
# elsewhere in this repo), no new host dependency.
#
# set -e note: every function here ends in an explicit `return 0` (or,
# for the handful meant to report true/false, is only ever called from an
# `if`/`while` condition — never as a bare statement). A bare
# `[[ cond ]] && cmd` (or `((expr))`, or `var=$(cmd)`) as a function's last
# statement becomes that function's exit status; if the function is later
# invoked as a plain statement and the condition is false, `set -e` kills
# the whole script. Direction C's build (#52) hit exactly this on its
# auth-mode toggle — the fix there, and the rule followed throughout this
# file, is: no bare conditional/arithmetic/command-substitution as the last
# line of a function, full stop.
# ---------------------------------------------------------------------------

UI_MAX_WIDTH=120
UI_MIN_WIDTH=56

ui_init() {
    # Box-drawing/dash/arrow glyphs below are multi-byte UTF-8. Bash's
    # `${#s}` only counts them as one character each when LC_CTYPE is
    # UTF-8-aware — under a plain C/POSIX locale it counts raw bytes,
    # which would silently break every width/padding calculation in this
    # file (border alignment, wrap points, all of it). Force a UTF-8
    # locale for this process if the current one isn't already one.
    if [[ "$(locale charmap 2>/dev/null || echo "")" != "UTF-8" ]]; then
        local cand
        for cand in C.UTF-8 C.utf8 en_US.UTF-8; do
            if locale -a 2>/dev/null | grep -qix "$cand"; then
                export LC_ALL="$cand"
                break
            fi
        done
    fi

    UI_BOLD=$(tput bold 2>/dev/null || true)
    UI_DIM=$(tput dim 2>/dev/null || true)
    UI_BLUE=$(tput setaf 4 2>/dev/null || true)
    UI_GREEN=$(tput setaf 2 2>/dev/null || true)
    UI_RED=$(tput setaf 1 2>/dev/null || true)
    UI_YELLOW=$(tput setaf 3 2>/dev/null || true)
    UI_RESET=$(tput sgr0 2>/dev/null || true)

    local cols=80
    if command -v tput >/dev/null 2>&1; then
        cols=$(tput cols 2>/dev/null || echo 80)
    fi
    if ! [[ "$cols" =~ ^[0-9]+$ ]]; then
        cols=80
    fi

    # Target 120 columns, shrink to fit a narrower real terminal, but never
    # below a floor that would make the box unusably squished.
    UI_TOTAL_WIDTH=$((cols - 2))
    if ((UI_TOTAL_WIDTH > UI_MAX_WIDTH)); then
        UI_TOTAL_WIDTH=$UI_MAX_WIDTH
    fi
    if ((UI_TOTAL_WIDTH < UI_MIN_WIDTH)); then
        UI_TOTAL_WIDTH=$UI_MIN_WIDTH
    fi
    UI_INNER_WIDTH=$((UI_TOTAL_WIDTH - 4))
    if ((UI_INNER_WIDTH < 1)); then
        UI_INNER_WIDTH=1
    fi
    return 0
}

# Strips ANSI SGR escape sequences so length/padding math is based on what a
# terminal actually renders, not the byte count of the color codes. Covers
# both CSI sequences (ESC [ ... letter — color/bold/reset) and the 2-byte
# charset-designation sequences (ESC ( letter / ESC ) letter) some terminfo
# entries fold into sgr0 (this terminal's sgr0 is `ESC(B ESC[m`, not just
# `ESC[m` — a naive CSI-only strip leaves a stray "(B" as visible text).
ui_strip_ansi() {
    printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b[()][A-Za-z0-9]//g'
    return 0
}

ui_mask() {
    local s="$1"
    printf '%*s' "${#s}" '' | tr ' ' '*'
    return 0
}

# Repeats a single (possibly multi-byte) character to fill the horizontal
# border. Built via parameter substitution, not `tr` — `tr` operates
# byte-wise and can mangle multi-byte UTF-8 box-drawing characters under a
# non-UTF-8 locale.
ui_hline() {
    local ch="${1:-─}" n=$((UI_TOTAL_WIDTH - 2)) out
    printf -v out '%*s' "$n" ''
    printf '%s' "${out// /$ch}"
    return 0
}

ui_box_top() {
    printf '%s┌%s┐%s\n' "$UI_BLUE" "$(ui_hline)" "$UI_RESET"
    return 0
}

ui_box_bottom() {
    printf '%s└%s┘%s\n' "$UI_BLUE" "$(ui_hline)" "$UI_RESET"
    return 0
}

ui_box_div() {
    printf '%s├%s┤%s\n' "$UI_BLUE" "$(ui_hline)" "$UI_RESET"
    return 0
}

# Word-wraps plain (ANSI-free) text into UI_WRAP_LINES, each line at most
# UI_INNER_WIDTH visible characters. Breaks at the last space before the
# limit when one exists; hard-splits otherwise (e.g. one long unbroken path).
ui_wrap_plain() {
    local text="$1" field=$UI_INNER_WIDTH
    UI_WRAP_LINES=()
    if [[ -z "$text" ]]; then
        UI_WRAP_LINES=("")
        return 0
    fi
    if ((field < 1)); then
        UI_WRAP_LINES=("$text")
        return 0
    fi
    local remaining="$text" line
    while [[ -n "$remaining" ]]; do
        if ((${#remaining} <= field)); then
            UI_WRAP_LINES+=("$remaining")
            break
        fi
        line="${remaining:0:field}"
        if [[ "${remaining:field:1}" != " " && "$line" == *" "* ]]; then
            line="${line% *}"
        fi
        if [[ -z "$line" ]]; then
            line="${remaining:0:field}"
        fi
        UI_WRAP_LINES+=("$line")
        remaining="${remaining:${#line}}"
        remaining="${remaining# }"
    done
    return 0
}

# Renders one already-fitted (<= UI_INNER_WIDTH visible chars) physical box
# line: left border, content padded to the inner width from its *visible*
# length, right border. This is the one place that guarantees the right
# border never drifts — every caller funnels through here.
ui_box_render_line() {
    local content="$1" plainlen="$2"
    local pad=$((UI_INNER_WIDTH - plainlen))
    if ((pad < 0)); then
        pad=0
    fi
    printf '%s│%s %s%*s %s│%s' "$UI_BLUE" "$UI_RESET" "$content" "$pad" "" "$UI_BLUE" "$UI_RESET"
    return 0
}

# ui_box_compose <content>
# Fills UI_BOX_LINES with one or more rendered physical lines for <content>.
# Colour is preserved when the line fits as-is (the common case at a
# 120-column target). When it doesn't fit, the line is word-wrapped instead
# of truncated — this is the fix for direction B's "..." clipping bug, which
# the owner hit in testing. Wrapping works on the ANSI-stripped text, so
# styling is dropped on wrapped output; that's a deliberate trade-off, not
# an oversight — this path only triggers for genuinely long content on a
# narrow terminal, and getting border alignment right matters far more there
# than preserving color on it.
ui_box_compose() {
    local content="$1" plain
    plain="$(ui_strip_ansi "$content")"
    UI_BOX_LINES=()
    if ((${#plain} <= UI_INNER_WIDTH)); then
        UI_BOX_LINES=("$(ui_box_render_line "$content" "${#plain}")")
        return 0
    fi
    ui_wrap_plain "$plain"
    local wl
    for wl in "${UI_WRAP_LINES[@]}"; do
        UI_BOX_LINES+=("$(ui_box_render_line "$wl" "${#wl}")")
    done
    return 0
}

# ui_box_line <content>
# Prints one or more bordered lines for static (non-live-redrawn) box
# content — the profile-selection panel, the alias panel, informational
# text. Box grows downward naturally since this just appends lines.
ui_box_line() {
    ui_box_compose "$1"
    local l
    for l in "${UI_BOX_LINES[@]}"; do
        printf '%s\n' "$l"
    done
    return 0
}

# Reads one logical keypress: prints ENTER, UP, DOWN, ESC, or the literal
# character. Arrow keys arrive as a 3-byte escape sequence.
ui_read_key() {
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
    return 0
}

ui_cursor_hide() {
    tput civis 2>/dev/null || true
    return 0
}

ui_cursor_show() {
    tput cnorm 2>/dev/null || true
    return 0
}

# Alternate-screen helpers. ui_alt_enter installs a trap so that a script
# error under `set -e`, or Ctrl-C, while inside an alt-screen segment always
# restores the real terminal (visible cursor, normal buffer) instead of
# leaving it stuck — neither direction A nor C's build handled this fully.
# ui_alt_exit clears the trap on the normal, successful exit path so it
# doesn't fire twice.
ui_alt_cleanup() {
    tput rmcup 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    return 0
}

ui_alt_enter() {
    tput civis 2>/dev/null || true
    tput smcup 2>/dev/null || true
    trap 'ui_alt_cleanup' EXIT
    trap 'ui_alt_cleanup; exit 130' INT TERM
    return 0
}

ui_alt_exit() {
    trap - EXIT INT TERM
    ui_alt_cleanup
    return 0
}

# ---------------------------------------------------------------------------
# Setup steps — called in order by every profiles/*/setup.sh.
# ---------------------------------------------------------------------------

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
# The settings dashboard: one alt-screen box, every field navigable via
# Up/Down at once, Enter edits/toggles the selected row, CONFIRM commits
# everything (blocked with an inline error if apikey mode has no key yet).
# common_prompt_auth/common_prompt_mounts/common_prompt_git are the three
# call sites every profile's setup.sh invokes (unchanged names/order); they
# all funnel into _common_ensure_dashboard, which runs the real interactive
# loop exactly once and is a no-op on the later two calls.
# ---------------------------------------------------------------------------

declare -A _DASH_ROW_START=()
declare -A _DASH_ROW_COUNT=()

# Rows that don't apply to the current state (e.g. Base URL/API Key/Model
# once SSO is selected) are skipped during navigation. Always called from an
# `if`/`while` condition — never as a bare statement — so its own possibly-
# false exit status never reaches `set -e`.
_dash_row_enabled() {
    case "$1" in
        model) [[ -n "$API_KEY" ]] ;;
        git_email) [[ -n "$GIT_USER_NAME" ]] ;;
        alias_name) [[ -n "$_DASH_ALIAS_RCFILE" ]] ;;
        *) return 0 ;;
    esac
}

_dash_append() {
    ui_box_compose "$1"
    _DASH_LINES+=("${UI_BOX_LINES[@]}")
    return 0
}

# Builds the composed value/label text for one dashboard row (see
# ui_box_compose for how it's turned into aligned, border-safe physical
# lines). "Default Auth Mode" (not just "Auth Mode") plus the inline hint is
# the label fix from testing: this field is a default only, overridable
# per-run via `claude.sh --auth=`, not a permanent choice.
_dash_compose_row() {
    local id="$1" label="" value="" enabled=1 selected=0
    if ! _dash_row_enabled "$id"; then
        enabled=0
    fi
    if [[ "${_DASH_ROW_IDS[$_DASH_SEL]}" == "$id" ]]; then
        selected=1
    fi

    case "$id" in
        auth_mode)
            label="Default Auth Mode"
            value="${AUTH_MODE}   ${UI_DIM}[Enter: toggle — a default only, override per run with --auth=sso|apikey]${UI_RESET}"
            ;;
        base_url)
            label="API Gateway"
            value="${BASE_URL:-<none>}   ${UI_DIM}[Enter: cycle]${UI_RESET}"
            ;;
        api_key)
            label="API Key"
            if [[ -n "$API_KEY" ]]; then
                value="$(ui_mask "$API_KEY")   ${UI_GREEN}set${UI_RESET}"
            elif [[ "$AUTH_MODE" == "apikey" ]]; then
                value="${UI_RED}(required — Enter to set)${UI_RESET}"
            else
                value="${UI_DIM}(optional — set to allow occasional --auth=apikey overrides)${UI_RESET}"
            fi
            ;;
        model)
            label="Model"
            if ((enabled)); then
                if ((${#_DASH_FETCHED_MODELS[@]} > 0)); then
                    value="${ANTHROPIC_MODEL}   ${UI_DIM}[Enter: cycle fetched models]${UI_RESET}"
                else
                    value="${ANTHROPIC_MODEL:-<none>}   ${UI_DIM}[Enter: edit]${UI_RESET}"
                fi
            else
                value="${UI_DIM}(enter API key first)${UI_RESET}"
            fi
            ;;
        ssh_dir)
            label="SSH Key Dir"
            value="${SSH_DIR:-(skip)}   ${UI_DIM}[Enter: edit, 'skip' to omit]${UI_RESET}"
            ;;
        workdir)
            label="Default Workspace"
            value="${WORKDIR_INPUT:-\$PWD at runtime}   ${UI_DIM}[Enter: edit]${UI_RESET}"
            ;;
        git_name)
            label="Git user.name"
            value="${GIT_USER_NAME:-(skip)}   ${UI_DIM}[Enter: edit]${UI_RESET}"
            ;;
        git_email)
            label="Git user.email"
            if ((enabled)); then
                value="${GIT_USER_EMAIL:-(skip)}   ${UI_DIM}[Enter: edit]${UI_RESET}"
            else
                value="${UI_DIM}(set git user.name first)${UI_RESET}"
            fi
            ;;
        alias_name)
            label="Shell Alias"
            if ! ((enabled)); then
                value="${UI_DIM}(unsupported OS — add manually: alias <name>='${REPO_DIR}/claude.sh')${UI_RESET}"
            elif [[ "$_DASH_ALIAS_ACTION" == "conflict" ]]; then
                value="${UI_YELLOW}${ALIAS_NAME}${UI_RESET}   ${UI_DIM}[name already used elsewhere — Enter to resolve]${UI_RESET}"
            else
                value="${ALIAS_NAME}   ${UI_DIM}[Enter: edit]${UI_RESET}"
            fi
            ;;
        confirm)
            if [[ "$AUTH_MODE" == "apikey" && -z "$API_KEY" ]]; then
                value="${UI_YELLOW}▶ CONFIRM${UI_RESET}  ${UI_DIM}(blocked — API key required above)${UI_RESET}"
            else
                value="${UI_GREEN}${UI_BOLD}▶ CONFIRM${UI_RESET}"
            fi
            ;;
    esac

    local marker="  " lcol="$UI_RESET"
    if ((selected)); then
        marker="${UI_BOLD}${UI_BLUE}> ${UI_RESET}"
        lcol="${UI_BOLD}"
    fi
    local full
    if [[ -n "$label" ]]; then
        full="$(printf '%s%s%-20s%s %s' "$marker" "$lcol" "${label}:" "$UI_RESET" "$value")"
    else
        full="$(printf '%s%s' "$marker" "$value")"
    fi
    ui_box_compose "$full"
    return 0
}

# Recomputes the whole box's interior content top to bottom and records
# where each row starts (_DASH_ROW_START) and how many physical lines it
# currently occupies (_DASH_ROW_COUNT) — a row can span more than one
# physical line when its value had to wrap. Layout is recomputed in full on
# every value change, so a row growing/shrinking never misaligns anything
# below it; only pure Up/Down navigation uses the cheaper partial redraw
# (see _dash_redraw_row), which is safe because the selection marker never
# changes a row's visible length.
_dash_layout() {
    _DASH_LINES=()
    _dash_append "${UI_BOLD}${UI_BLUE}claude-sandbox — Setup Dashboard${UI_RESET}"
    _dash_append "${UI_DIM}Up/Down move   Enter edits or toggles the selected row   q aborts${UI_RESET}"
    _dash_append ""

    local prof
    prof=$(cat "$REPO_DIR/.claude-profile" 2>/dev/null || echo "?")
    _dash_append "$(printf '  %-20s %s%s%s   %s(locked for this checkout)%s' "Profile:" "$UI_BOLD" "$prof" "$UI_RESET" "$UI_DIM" "$UI_RESET")"
    _dash_append ""

    local id
    for id in "${_DASH_ROW_IDS[@]}"; do
        # Blank spacer between the last question row and CONFIRM, so it
        # reads as visually separate from the fields above it.
        if [[ "$id" == "confirm" ]]; then
            _dash_append ""
        fi
        _dash_compose_row "$id"
        _DASH_ROW_START[$id]=${#_DASH_LINES[@]}
        _DASH_ROW_COUNT[$id]=${#UI_BOX_LINES[@]}
        _DASH_LINES+=("${UI_BOX_LINES[@]}")
    done

    _dash_append ""
    _dash_append "${UI_DIM}Red = required and missing. Enter on CONFIRM writes .env and starts the image build.${UI_RESET}"
    _dash_append ""
    _DASH_STATUS_START=${#_DASH_LINES[@]}
    if [[ -n "$_DASH_STATUS_MSG" ]]; then
        _dash_append "  ${UI_RED}${_DASH_STATUS_MSG}${UI_RESET}"
    else
        _dash_append ""
    fi
    return 0
}

_dash_draw_full() {
    _dash_layout
    clear
    ui_box_top
    local i n=${#_DASH_LINES[@]}
    for ((i = 0; i < n; i++)); do
        tput cup $((i + 1)) 0 2>/dev/null || true
        printf '%s' "${_DASH_LINES[$i]}"
    done
    tput cup $((n + 1)) 0 2>/dev/null || true
    ui_box_bottom
    return 0
}

# Redraws just one row in place, at its last-computed position — used for
# pure Up/Down movement so navigating doesn't repaint (and flicker) the
# whole box.
_dash_redraw_row() {
    local id="$1"
    _dash_compose_row "$id"
    local start="${_DASH_ROW_START[$id]}" i n=${#UI_BOX_LINES[@]}
    for ((i = 0; i < n; i++)); do
        tput cup $((start + i + 1)) 0 2>/dev/null || true
        tput el 2>/dev/null || true
        printf '%s' "${UI_BOX_LINES[$i]}"
    done
    return 0
}

_dash_move() {
    local delta="$1" n=${#_DASH_ROW_IDS[@]} tries=0 new="$_DASH_SEL" old="$_DASH_SEL"
    while ((tries < n)); do
        new=$(((new + delta + n) % n))
        if _dash_row_enabled "${_DASH_ROW_IDS[$new]}"; then
            _DASH_SEL=$new
            _dash_redraw_row "${_DASH_ROW_IDS[$old]}"
            _dash_redraw_row "${_DASH_ROW_IDS[$new]}"
            return 0
        fi
        tries=$((tries + 1))
    done
    return 0
}

# Prints the left border plus the same 2-character marker column a selected
# row's normal (non-editing) display uses. Without this, dropping into
# edit mode would print just the border ("│ ") and the edited row's text
# would start 2 columns to the left of where it sits once editing ends —
# every row being edited IS the selected row, so the marker is always the
# selected (bold blue "> ") one.
_dash_edit_marker() {
    printf '%s│%s %s%s> %s' "$UI_BLUE" "$UI_RESET" "$UI_BOLD" "$UI_BLUE" "$UI_RESET"
    return 0
}

# Edits a plain-text row in place: shows the cursor, drops into cooked-mode
# `read -e` right under the box's left border at that row's position, then
# hides the cursor again. varname is a global set by common_prompt_auth's
# contract (AUTH_MODE, WORKDIR_INPUT, etc.) — safe to bind a nameref to
# directly since these are always real globals, never another nameref.
_dash_edit_text() {
    local id="$1" label="$2" varname="$3"
    local -n _dash_target="$varname"
    local start="${_DASH_ROW_START[$id]}"
    ui_cursor_show
    tput cup $((start + 1)) 0 2>/dev/null || true
    tput el 2>/dev/null || true
    _dash_edit_marker
    read -e -r -i "$_dash_target" -p "${label}: " _dash_target || true
    ui_cursor_hide
    return 0
}

_dash_edit_sshdir() {
    local start="${_DASH_ROW_START[ssh_dir]}" input
    ui_cursor_show
    tput cup $((start + 1)) 0 2>/dev/null || true
    tput el 2>/dev/null || true
    _dash_edit_marker
    read -e -r -i "${SSH_DIR:-$HOME/.ssh}" -p "SSH key directory ('skip' to omit mount): " input || true
    if [[ "${input,,}" == "skip" ]]; then
        SSH_DIR=""
    else
        SSH_DIR="${input:-$HOME/.ssh}"
    fi
    ui_cursor_hide
    return 0
}

# Reactive fetch: pulled the moment the key changes (see _dash_edit_apikey)
# rather than as a separate prompt step.
_dash_fetch_models() {
    _DASH_FETCHED_MODELS=()
    _DASH_MODEL_IDX=0
    if [[ -z "$BASE_URL" || -z "$API_KEY" ]]; then
        return 0
    fi
    local start="${_DASH_ROW_START[model]}"
    tput cup $((start + 1)) 0 2>/dev/null || true
    tput el 2>/dev/null || true
    _dash_edit_marker
    printf ' Model: %sfetching from %s...%s' "$UI_DIM" "$BASE_URL" "$UI_RESET"
    local model
    while IFS= read -r model; do
        if [[ -n "$model" ]]; then
            _DASH_FETCHED_MODELS+=("$model")
        fi
    done < <(curl -sf "$BASE_URL/v1/models" \
        -H "Authorization: Bearer $API_KEY" 2>/dev/null |
        grep -oE '"id" *: *"claude[^"]*"' |
        grep -oE 'claude[^"]+' |
        sort -r)
    if ((${#_DASH_FETCHED_MODELS[@]} > 0)); then
        local i=0 m
        for m in "${_DASH_FETCHED_MODELS[@]}"; do
            if [[ "$m" == "claude-sonnet-5" ]]; then
                _DASH_MODEL_IDX=$i
            fi
            i=$((i + 1))
        done
        ANTHROPIC_MODEL="${_DASH_FETCHED_MODELS[$_DASH_MODEL_IDX]}"
    elif [[ -z "$ANTHROPIC_MODEL" ]]; then
        ANTHROPIC_MODEL="claude-sonnet-5"
    fi
    return 0
}

_dash_edit_apikey() {
    local start="${_DASH_ROW_START[api_key]}" prompt input
    ui_cursor_show
    tput cup $((start + 1)) 0 2>/dev/null || true
    tput el 2>/dev/null || true
    prompt="API Key: "
    if [[ -n "$API_KEY" ]]; then
        prompt="API Key (blank = keep current): "
    fi
    _dash_edit_marker
    read -rs -p "$prompt" input || true
    echo ""
    if [[ -n "$input" ]]; then
        API_KEY="$input"
        _dash_fetch_models
    fi
    ui_cursor_hide
    return 0
}

# Non-interactively (re)resolves _DASH_ALIAS_ACTION/_DASH_ALIAS_OLD_NAME/
# _DASH_ALIAS_CONFLICT_LINE for the current $ALIAS_NAME against
# _DASH_ALIAS_RCFILE. An unrelated conflicting alias is left flagged as
# "conflict" rather than silently resolved — _dash_edit_alias_name (or, if
# the row is never revisited, _dash_try_confirm) decides what to do about it.
_dash_resolve_alias_action() {
    _DASH_ALIAS_OLD_NAME=""
    _DASH_ALIAS_CONFLICT_LINE=""
    if [[ -n "$_DASH_ALIAS_EXISTING_NAME" ]]; then
        if [[ "$ALIAS_NAME" == "$_DASH_ALIAS_EXISTING_NAME" ]]; then
            _DASH_ALIAS_ACTION="unchanged"
        else
            _DASH_ALIAS_ACTION="rename"
            _DASH_ALIAS_OLD_NAME="$_DASH_ALIAS_EXISTING_NAME"
        fi
        return 0
    fi
    if grep -qE "^alias ${ALIAS_NAME}=" "$_DASH_ALIAS_RCFILE" 2>/dev/null; then
        _DASH_ALIAS_CONFLICT_LINE=$(grep -E "^alias ${ALIAS_NAME}=" "$_DASH_ALIAS_RCFILE")
        _DASH_ALIAS_ACTION="conflict"
        return 0
    fi
    _DASH_ALIAS_ACTION="add"
    return 0
}

# Edits the alias-name row in place, same as _dash_edit_text, but with the
# rename/existing-alias/name-conflict resolution claude.sh's old standalone
# alias prompt used to do — folded in here since the prompt itself now lives
# in this row instead of its own screen. A name conflict with an unrelated
# alias gets an inline y/n follow-up at the same row.
_dash_edit_alias_name() {
    local start="${_DASH_ROW_START[alias_name]}" input
    ui_cursor_show
    tput cup $((start + 1)) 0 2>/dev/null || true
    tput el 2>/dev/null || true
    _dash_edit_marker
    read -e -r -i "$ALIAS_NAME" -p "Alias name: " input || true
    input="${input//[^a-zA-Z0-9_-]/}"
    if [[ -z "$input" ]]; then
        input="$ALIAS_NAME"
    fi
    ALIAS_NAME="$input"
    _dash_resolve_alias_action

    if [[ "$_DASH_ALIAS_ACTION" == "conflict" ]]; then
        local overwrite=""
        tput cup $((start + 1)) 0 2>/dev/null || true
        tput el 2>/dev/null || true
        _dash_edit_marker
        read -r -p "'$ALIAS_NAME' is already used ($_DASH_ALIAS_CONFLICT_LINE) — overwrite? [y/N]: " overwrite || true
        if [[ "${overwrite,,}" == "y" ]]; then
            _DASH_ALIAS_ACTION="overwrite"
        else
            _DASH_ALIAS_ACTION="skip"
        fi
    fi
    ui_cursor_hide
    return 0
}

# Applies whatever the alias_name row resolved: the actual rc-file write,
# plus the $REPO_DIR/.claude-alias marker file claude.sh's closing summary
# reads back purely for display (this runs inside the `bash setup.sh`
# subprocess, so ALIAS_NAME/_DASH_ALIAS_RCFILE don't survive back into
# claude.sh's own process — the same "write a file, read it back" pattern
# claude.sh already uses for .env). Called once CONFIRM's other validation
# has passed, right before _DASH_DONE is set.
_dash_apply_alias() {
    case "$_DASH_ALIAS_ACTION" in
        rename)
            sed -i "/^alias ${_DASH_ALIAS_OLD_NAME}=/d" "$_DASH_ALIAS_RCFILE"
            echo "alias ${ALIAS_NAME}='${REPO_DIR}/claude.sh'" >>"$_DASH_ALIAS_RCFILE"
            ;;
        overwrite)
            sed -i "s|^alias ${ALIAS_NAME}=.*|alias ${ALIAS_NAME}='${REPO_DIR}/claude.sh'|" "$_DASH_ALIAS_RCFILE"
            ;;
        add)
            echo "alias ${ALIAS_NAME}='${REPO_DIR}/claude.sh'" >>"$_DASH_ALIAS_RCFILE"
            ;;
        unchanged | skip | none | conflict) : ;;
    esac

    local marker="$REPO_DIR/.claude-alias"
    case "$_DASH_ALIAS_ACTION" in
        add | rename | overwrite | unchanged)
            printf '%s\n%s\n' "$ALIAS_NAME" "$_DASH_ALIAS_RCFILE" >"$marker"
            ;;
        *)
            rm -f "$marker"
            ;;
    esac
    return 0
}

_dash_try_confirm() {
    if [[ "$AUTH_MODE" == "apikey" && -z "$API_KEY" ]]; then
        _DASH_STATUS_MSG="API key is required for apikey auth mode — select the API Key row and press Enter to set it."
        return 0
    fi
    # Left unresolved (row never revisited after a conflict was flagged) —
    # don't touch an alias that isn't ours without explicit confirmation.
    if [[ "$_DASH_ALIAS_ACTION" == "conflict" ]]; then
        _DASH_ALIAS_ACTION="skip"
    fi
    _dash_apply_alias
    _DASH_STATUS_MSG=""
    _DASH_DONE=1
    return 0
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
            ;;
        base_url)
            case "$_DASH_BASEURL_MODE" in
                fuelix)
                    _DASH_BASEURL_MODE="anthropic"
                    BASE_URL="https://api.anthropic.com"
                    ;;
                anthropic)
                    _DASH_BASEURL_MODE="custom"
                    _dash_edit_text base_url "API Gateway" BASE_URL
                    ;;
                *)
                    _DASH_BASEURL_MODE="fuelix"
                    BASE_URL="https://api.fuelix.ai"
                    ;;
            esac
            ;;
        api_key) _dash_edit_apikey ;;
        model)
            if [[ -n "$API_KEY" ]]; then
                if ((${#_DASH_FETCHED_MODELS[@]} > 0)); then
                    _DASH_MODEL_IDX=$(((_DASH_MODEL_IDX + 1) % ${#_DASH_FETCHED_MODELS[@]}))
                    ANTHROPIC_MODEL="${_DASH_FETCHED_MODELS[$_DASH_MODEL_IDX]}"
                else
                    _dash_edit_text model "Model ID" ANTHROPIC_MODEL
                fi
            fi
            ;;
        ssh_dir) _dash_edit_sshdir ;;
        workdir) _dash_edit_text workdir "Default workspace" WORKDIR_INPUT ;;
        git_name) _dash_edit_text git_name "Git user.name" GIT_USER_NAME ;;
        git_email)
            if [[ -n "$GIT_USER_NAME" ]]; then
                _dash_edit_text git_email "Git user.email" GIT_USER_EMAIL
            fi
            ;;
        alias_name)
            if [[ -n "$_DASH_ALIAS_RCFILE" ]]; then
                _dash_edit_alias_name
            fi
            ;;
        confirm) _dash_try_confirm ;;
    esac
    return 0
}

# The real workhorse behind common_prompt_auth/common_prompt_mounts/
# common_prompt_git — see the block comment above. Runs once per setup.sh
# invocation no matter which of the three names is called first.
_common_ensure_dashboard() {
    if [[ -n "${_COMMON_DASHBOARD_DONE:-}" ]]; then
        return 0
    fi
    _COMMON_DASHBOARD_DONE=1

    ui_init

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

    # Alias row init — search by repo path (not name) so an existing alias is
    # found regardless of what name it was created under last time.
    _DASH_ALIAS_RCFILE="$(_common_alias_rcfile)"
    _DASH_ALIAS_EXISTING_NAME=""
    local existing_line
    if [[ -n "$_DASH_ALIAS_RCFILE" ]]; then
        existing_line=$(grep -E "^alias [^=]+='${REPO_DIR}/claude\.sh'" "$_DASH_ALIAS_RCFILE" 2>/dev/null || true)
        if [[ -n "$existing_line" ]]; then
            _DASH_ALIAS_EXISTING_NAME="${existing_line#alias }"
            _DASH_ALIAS_EXISTING_NAME="${_DASH_ALIAS_EXISTING_NAME%%=*}"
        fi
    fi
    ALIAS_NAME="${_DASH_ALIAS_EXISTING_NAME:-claude-sandbox}"
    _DASH_ALIAS_ACTION="none"
    if [[ -n "$_DASH_ALIAS_RCFILE" ]]; then
        _dash_resolve_alias_action
    fi

    _DASH_ROW_IDS=(auth_mode base_url api_key model ssh_dir workdir git_name git_email alias_name confirm)
    _DASH_SEL=0
    _DASH_STATUS_MSG=""
    _DASH_DONE=""

    ui_alt_enter
    _dash_draw_full
    local key
    while [[ -z "$_DASH_DONE" ]]; do
        key=$(ui_read_key)
        case "$key" in
            UP) _dash_move -1 ;;
            DOWN) _dash_move 1 ;;
            ENTER)
                _dash_activate_row "${_DASH_ROW_IDS[$_DASH_SEL]}"
                _dash_draw_full
                ;;
            q | Q)
                ui_alt_exit
                echo ""
                echo "Setup aborted — no changes written."
                exit 1
                ;;
            *) : ;;
        esac
    done
    ui_alt_exit

    echo ""
    echo "${UI_GREEN}Configuration confirmed.${UI_RESET}"
    if [[ -z "$GIT_USER_NAME" ]]; then
        GIT_USER_EMAIL=""
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Shell alias handling. The alias_name dashboard row (see _dash_edit_alias_name/
# _dash_resolve_alias_action/_dash_apply_alias above) resolves and applies the
# alias entirely inside the dashboard, right before CONFIRM — this runs inside
# the `bash setup.sh` subprocess, so the resolved name/rc-file don't survive
# back into claude.sh's own process for the closing summary. Instead of
# threading state back through a pipe, the resolved values get handed back
# purely for display via a small gitignored marker file, $REPO_DIR/.claude-alias
# (line 1: alias name, line 2: rc file path) — the same "write a file, read it
# back" pattern claude.sh already uses for .env.
# ---------------------------------------------------------------------------

_common_alias_rcfile() {
    case "$(uname -s)" in
        Darwin*)
            if [[ "${SHELL:-}" == */zsh ]]; then
                printf '%s' "$HOME/.zshrc"
            else
                printf '%s' "$HOME/.bash_profile"
            fi
            ;;
        Linux*)
            printf '%s' "$HOME/.bash_aliases" # Linux and WSL
            ;;
        *)
            printf '%s' "" # WSL/macOS paths are untested — logic based on standard conventions
            ;;
    esac
    return 0
}

common_prompt_auth() {
    _common_ensure_dashboard
    return 0
}

common_prompt_mounts() {
    _common_ensure_dashboard
    return 0
}

common_prompt_git() {
    _common_ensure_dashboard
    return 0
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
