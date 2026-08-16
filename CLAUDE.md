# claude-sandbox — Developer Guide

Companion to [README.md](README.md) (user-facing). This file is developer/LLM-facing: repo
conventions and the design rules behind them.

## Threat model

- Org-managed Claude Code settings (managed/enterprise environments) can execute code and touch
  the filesystem as part of normal tooling.
- Running inside Docker contains that: shell execution and rc-file-style writes stay inside
  `.home/`, never the host's real home directory.
- `--read-only` rootfs + tmpfs `/tmp` (in `claude.sh`) enforces this structurally — writes outside
  `.home/`, the workdir, or `/tmp` fail loudly instead of landing somewhere unmonitored. Exists
  because auditing every current/future hook by reading its source doesn't scale.
- Not solved: telemetry still leaves the container over the network; org-managed settings still
  apply inside the container (one-time approval dialog per fresh `.home/`).
- Accepted risk: the Docker socket is mounted in for `docker`/`gh`/MCP use inside the container —
  threat model is contained execution, not container escape.

### Credential placement

- `apikey` mode — secret lives in `.env` (host-side, gitignored), injected via
  `-e ANTHROPIC_AUTH_TOKEN=...` at `docker run` time.
- `sso` mode — secret lives in `.home/.claude.json` (OAuth token from Claude Code's own login),
  never in `.env`.
- Don't cross them (convention, not code-enforced): `.env` is host-readable by anyone with
  checkout access; `.home/` is scoped to whatever already trusts the container.

## Repository structure

- `claude.sh` — single entry point: init/dispatch, flag parsing, `docker run`.
- `.env.example` — schema doc, committed. `.env` itself is gitignored.
- `.githooks/pre-commit` — shellcheck + shfmt on staged `*.sh`.
- `profiles/_common.sh` — shared `setup.sh` helpers (OS detect, prompts, `.env` write, build, seed).
- `profiles/<name>/{Dockerfile,docker-compose.yml,setup.sh}` — one dir per profile. Profile-specific
  notes live in that profile's own `CLAUDE.md`, not here.
- Two images: `claude-code:omc` (needs the `oh-my-claude-sisyphus` npm package) and
  `claude-code:base` (shared by `vanilla`/`aihero` — aihero's skill pack is files copied at setup
  time, not a system dependency).
- New profile convention: system deps → `Dockerfile`; config/skills/settings → `setup.sh`. No
  system dep beyond the base image → point `docker-compose.yml` at `claude-code:base` instead of
  building a new image.

## Key design decisions

- Profile is locked per checkout (`.claude-profile`, gitignored, written once by `init()`). No
  `--profile` override — would mix state from two plugin ecosystems into one `.home/`. New
  profile → new checkout.
- `.home/` is the entire container `$HOME`, not just `.claude/`. Container user/uid/gid are
  captured from the host at setup (`CONTAINER_USER/UID/GID` in `.env`) so mount ownership is
  always correct.
- Docker GID is detected at runtime (`getent group docker`), not hardcoded — varies per host.
- `--dangerously-skip-permissions` is baked into every image's `ENTRYPOINT`. `claude.sh --confirm`
  overrides the entrypoint to plain `claude` at `docker run` time for real permission prompts.
- Auth is injected via `-e` flags at `docker run`, never via `settings.json`.
- MCP servers are registered at user scope (`.home/.claude.json`, via `claude mcp add --scope user`
  in a one-off `docker run` from `common_register_mcp`), not project-scope `.mcp.json` — same
  reasoning as `.home/` being the whole `$HOME`: available across every project in the container,
  not one workdir. Slack (`common_prompt_mcp`/`common_register_mcp` in `_common.sh`, skippable via
  blank `SLACK_MCP_XOXB_TOKEN`) is the POC; it's the shape (npm stdio server + one token) future MCP
  integrations should copy — Confluence/Jira/AWS don't fit this shape as cleanly, see Roadmap.
- Slack MCP uses the `slack-mcp-server` npm package (korotovsky), not the official-looking
  `@modelcontextprotocol/server-slack` — that reference package is archived upstream
  (`modelcontextprotocol/servers-archived`) with an explicit "don't build new work on it" notice.
  Confirmed by `npm install` emitting a deprecation warning during a Dockerfile build; caught before
  merge, not after.
- `--recover` wipes `.env`/`.home/` and re-runs `setup.sh` for the already-locked profile — it never
  touches `.claude-profile`. Earlier it doubled as a profile-switcher (deleted `.claude-profile`
  too), which quietly defeated the profile-lock decision above; scoping it to the current profile
  closes that gap instead of just tidying its symptoms.
- `common_seed_gh_skill` (in `_common.sh`, called by every profile's `setup.sh`) seeds a
  `/gh-login` skill into `.home/.claude/skills/gh-login/`. Manual-invoke only
  (`disable-model-invocation: true`) — an OAuth login shouldn't trigger itself. `gh` is already in
  every Dockerfile; this just drives `gh auth login`'s device flow and surfaces the code/URL.

## Platform support

- Linux + native Docker Engine: the only path actually tested, across all three profiles.
- macOS / WSL2: real code paths exist (OS detection, GID handling, shell-rc selection), untested —
  Docker Desktop's virtualization differs enough that "code exists" ≠ "works."
- Native Windows shells (PowerShell/Git Bash/Cygwin): rejected outright by a guard in `claude.sh`.
  Use WSL2.
- First to hit macOS/WSL2 breakage: file an issue with what broke.

## Development workflow

- Shell scripts: shellcheck + shfmt (`-i 4 -ci`). Enable once per checkout:
  `git config core.hooksPath .githooks`. Hook lints staged `*.sh`, blocks on real findings,
  warns-and-skips if the tools aren't installed.
- No commits directly to `master`. Branch → commit → push → PR (what changed + how tested) →
  squash-merge after review.
- No automated test suite. Verify by running the affected profile(s):
  `./claude.sh --recover` re-runs setup for the locked profile in place, or a scoped `docker run`
  reproducing the relevant slice of `claude.sh`'s args. Changes to `profiles/_common.sh` or
  `claude.sh`'s docker args → smoke test all three profiles (shared code path).

## Roadmap

Phase 1 (core setup) and Phase 3 (docs) done. Phase 2 superseded — decisions captured inline above
as they were made. Phase 4 (MCP/tool integrations) started: `gh` OAuth device-flow auth + `/gh-login`
skill, and Slack MCP as the reusable-pattern POC, both done. GitHub MCP explicitly skipped — the
`@modelcontextprotocol/server-github` package needs its own `GITHUB_PERSONAL_ACCESS_TOKEN`, not
reusing `gh`'s OAuth session, doubling the credential surface for no real gain. Confluence, Jira,
AWS, Laravel Boost remain deferred and mostly at the scoping stage — see git history / `handoff.md`.
