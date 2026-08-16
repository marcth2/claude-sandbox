# aihero profile

- No extra system dependency — shares `claude-code:base` with `vanilla`, since the skill pack is
  just Markdown files, not a binary/package.
- `setup.sh` calls the shared `common_*` helpers, then git-clones `mattpocock/skills` into a temp
  dir and copies the non-deprecated skill directories into `.home/.claude/skills/`.
