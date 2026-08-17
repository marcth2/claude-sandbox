#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
HOME_DIR="$REPO_DIR/.home"

echo "=== Claude Docker — aihero Profile Setup ==="
echo ""

# shellcheck source=profiles/_common.sh
source "$REPO_DIR/profiles/_common.sh"

common_detect_os
common_prompt_auth
common_prompt_mounts
common_prompt_git
common_write_env
# shellcheck disable=SC2119  # common_build_image's --no-cache arg is optional; this call intentionally omits it
common_build_image
common_seed_home
common_seed_gh_skill

cat >"$HOME_DIR/.claude/settings.json" <<'SETTINGS'
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "skipDangerousModePermissionPrompt": true,
  "skipWorkflowUsageWarning": true,
  "alwaysThinkingEnabled": true,
  "spinnerTipsEnabled": true,
  "theme": "dark"
}
SETTINGS
echo "  settings.json written."

echo ""
echo "Installing mattpocock-skills into .home/.claude/skills/..."
SKILLS_TMP=$(mktemp -d)
trap 'rm -rf "$SKILLS_TMP"' EXIT
git clone --depth=1 https://github.com/mattpocock/skills.git "$SKILLS_TMP" 2>&1
mkdir -p "$HOME_DIR/.claude/skills"
while IFS= read -r -d '' skill_md; do
    skill_dir="$(dirname "$skill_md")"
    skill_name="$(basename "$skill_dir")"
    cp -r "$skill_dir" "$HOME_DIR/.claude/skills/$skill_name"
done < <(find "$SKILLS_TMP/skills" -name SKILL.md -not -path '*/deprecated/*' -print0)
skill_count=$(find "$HOME_DIR/.claude/skills" -mindepth 1 -maxdepth 1 -type d | wc -l)
echo "  $skill_count skills installed to .home/.claude/skills/"
