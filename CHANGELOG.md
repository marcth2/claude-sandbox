# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.1.1] — 2026-08-17

### Fixed

- `/gh-login` skill: `gh auth status`'s expected "not logged in yet" state (the normal case on a
  fresh container) no longer renders as a raw `Error: Exit code 1` tool block before Claude's own
  reassuring follow-up appears — the check now always exits 0 and the skill is told explicitly
  that this is the expected first-run state, not a failure.

### Docs

- Removed "prototype improvements to the install script's UX and output formatting" from the
  roadmap in CLAUDE.md — actioned by the setup-UX dashboard synthesis shipped in 1.1.0.

## [1.1.0] — 2026-08-17

Redesigned first-run setup UX: a single arrow-key-navigable dashboard replaces the old
"press Enter to accept every default" prompt sequence, synthesized from three prototype
directions built and tested against the setup-UX map (issue #45).

### Added

- Setup Dashboard (`profiles/_common.sh`): one alt-screen, box-drawn dashboard listing every
  first-run field — auth mode, API Gateway, API key, model, SSH key dir, workspace dir, git
  identity, shell alias — navigable with Up/Down/Enter, with a reactive model fetch once an API
  key is entered and CONFIRM blocked until required fields are set.
- Dynamic, word-wrapping box UI (`ui_box_*` helpers): border width tracks terminal width up to
  120 columns (down to a 56-column floor), wrapping long content instead of truncating it.
- Shell alias creation folded into the dashboard as its own row, immediately before CONFIRM, with
  true optional/skip semantics — clearing the field removes any existing alias rather than
  falling back to the proposed default name.
- Closing summary now reports the shell alias (when set) and combines the "source rc file" /
  "launch" steps into one `Run: ... && ... /gh-login` line that auto-triggers the `/gh-login`
  skill on first launch.

### Changed

- `claude.sh`'s profile picker uses the same partial-row-redraw technique as the dashboard,
  removing the full-screen repaint flicker on arrow-key navigation.
- API Gateway, API key, and model rows are editable regardless of default auth mode, so an
  SSO-default setup can still configure an API key for occasional `--auth=apikey` runs;
  validation at CONFIRM still only requires a key when auth mode is `apikey`.
- "Base URL" row relabeled "API Gateway" to match the closing summary's existing "Gateway:" label.

### Fixed

- Alt-screen segments (profile picker, dashboard) restore the terminal via a crash/Ctrl-C-safe
  `trap` instead of relying on the happy path to run `tput rmcup`.
- Box border alignment under terminals whose `tput sgr0` emits a trailing charset-designation
  escape, and under non-UTF-8 locales where multi-byte box-drawing/arrow glyphs were being
  counted as raw bytes instead of characters.

## [1.0.0] — 2026-08-16

Initial stable release. Dockerized Claude Code launcher with three profiles (`vanilla`, `omc`,
`aihero`), containment-by-construction, and a documentation set audited to match the code.

### Added

- `claude.sh` single entry point: first-run profile/auth/workspace/git-identity setup, then
  `docker run` dispatch on every subsequent invocation.
- Three profiles — `vanilla` (plain Claude Code), `omc` (+ oh-my-claude-sisyphus multi-agent
  orchestration), `aihero` (+ the AI Hero skill pack) — locked per checkout via `.claude-profile`,
  with `--recover` to wipe and rebuild `.env`/`.home/` for the already-selected profile.
- Two Docker images: `claude-code:base` (shared by `vanilla`/`aihero`) and `claude-code:omc`
  (extra npm dependency). See [docs/architecture.md](docs/architecture.md) for the build matrix.
- Two auth modes, deliberately not cross-wired: `apikey` (secret in host-side `.env`, injected via
  `-e ANTHROPIC_AUTH_TOKEN`) and `sso` (OAuth token in `.home/.claude.json`, never written to
  `.env`).
- `/gh-login` skill (seeded into every profile's `.home/.claude/skills/`) driving `gh auth login`'s
  OAuth device flow, plus a closing-banner reminder to run it after first setup.
- `--confirm` flag to use Claude Code's real permission prompts instead of the
  `--dangerously-skip-permissions` baked into each image's `ENTRYPOINT`.
- `.githooks/pre-commit`: shellcheck + shfmt on staged `*.sh`, enabled via
  `git config core.hooksPath .githooks`.
- `docs/architecture.md`: Mermaid diagrams of the profile/image build matrix and the `.home/`
  mount + auth-injection data flow.

### Security

- `--read-only` rootfs + tmpfs `/tmp`: writes outside `.home/`, the workdir, or `/tmp` fail loudly
  instead of landing somewhere unmonitored.
- Container resource limits (`--memory 2g --cpus 1.5 --pids-limit 256`), `--cap-drop ALL`, and
  `--security-opt no-new-privileges:true` on every invocation.
- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` scoped to `apikey`/gateway auth only.

### Fixed

- Shell injection, macOS bash-compat, input-validation, and `mktemp`-leak issues found during
  Phase 1 testing.
- `omc` profile: wrong npm package name, `omc setup` not actually wired up.
- Hardcoded username/UID in Docker builds; Docker GID now detected at runtime via
  `getent group docker` instead of being hardcoded.
- Stale FuelIX-specific "unlimited" auth claims and a stale example model in `.env.example` and
  README.md.
- `--reset` renamed to `--recover` and scoped to the checkout's already-locked profile (previously
  it could also clear the profile lock, defeating the point of locking it).

### Docs

- Added README.md (user-facing) and CLAUDE.md (developer/LLM-facing design decisions), replacing
  the running `handoff.md` dev log once GitHub Issues covered its history.
- Full documentation audit: fixed drift between README/CLAUDE.md/profile CLAUDE.mds and actual
  `claude.sh`/`setup.sh` behavior, documented previously-unwritten behavior (env vars, resource
  limits, CLI short flags, a missing Dockerfile comment), and added `docs/architecture.md`.
