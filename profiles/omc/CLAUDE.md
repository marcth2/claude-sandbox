# omc profile

- Extra system dependency: the `oh-my-claude-sisyphus` npm package, installed in `Dockerfile`.
  This is why omc gets its own image (`claude-code:omc`) instead of sharing `claude-code:base`.
- `setup.sh` calls the shared `common_*` helpers, copies the host's `~/.claude/CLAUDE.md` into
  `.home/.claude/CLAUDE.md` if present, then runs `omc setup --quiet` (which merges its own
  hooks/statusLine into `settings.json` and its own content block into `CLAUDE.md`).
- `omc doctor conflicts` reports a "legacy skills colliding with plugin skill names" warning on a
  clean setup — a pre-existing quirk of `omc` itself, not a regression to chase down.
