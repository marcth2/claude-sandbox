# claude-sandbox

Run [Claude Code](https://claude.com/claude-code) entirely inside Docker. Claude Code is never
installed on the host — the container is the sandbox.

## Why

In managed/enterprise environments, Claude Code can be configured with organization-level settings
that run their own logic as part of normal tooling (telemetry, compliance checks, etc.). Running
Claude Code inside a container keeps that activity, and anything it touches on disk, scoped to the
container's `.home/` mount instead of your real home directory. See
[CLAUDE.md](CLAUDE.md#threat-model) for the full threat model.

## System requirements

- **Docker Engine** with the Compose v2 plugin (`docker compose`, not the standalone
  `docker-compose`). Developed against Docker 29.x / Compose v5.x — check with `docker -v` and
  `docker compose version`.
- **bash 4+** (uses `${var,,}` case conversion and `read -e`/`read -i` readline features). macOS
  ships bash 3.2 by default — install a newer bash (e.g. `brew install bash`) and run `claude.sh`
  with it explicitly if you're on macOS.
- **git**, for cloning and for the git-identity prompt during setup.

## Platform support

Linux with native Docker Engine is the only platform that's actually been exercised end-to-end.
macOS and WSL2 have real, implemented code paths (not stubs), but nobody has run them yet — see
[CLAUDE.md](CLAUDE.md#platform-support) for specifics. Native Windows shells (PowerShell, Git Bash,
Cygwin) are rejected outright; run from a WSL2 terminal instead. If you hit problems on macOS or
Windows, please file an issue.

## Quick start

```bash
git clone git@github.com:marcth2/claude-sandbox.git
cd claude-sandbox
./claude.sh
```

First run walks you through:
1. **Pick a profile** — `vanilla` (plain Claude Code), `omc` (+ oh-my-claude-sisyphus multi-agent
   orchestration), or `aihero` (+ the [AI Hero](https://github.com/mattpocock/skills) skill pack).
   This choice is locked in for the checkout — to try a different profile, clone the repo again.
2. **Auth mode** — `apikey` (via a gateway) or `sso` (OAuth via claude.ai).
3. **SSH key directory** — optional, for `git push` from inside the container.
4. **Default workspace** — optional; falls back to `$PWD` at runtime if unset.
5. **Git identity** — defaults to your host's `git config --global user.name`/`user.email`.

Setup then builds the Docker image and writes `.env`. It also offers to add a shell alias
(default name: `claude-sandbox`) so you can just type that instead of the full path.

Subsequent runs: `./claude.sh` (or your alias) launches straight into a container Claude Code
session in your current directory.

## Profiles

| Profile | What it adds |
|---|---|
| `vanilla` | Plain Claude Code, no plugins |
| `omc` | [oh-my-claude-sisyphus](https://www.npmjs.com/package/oh-my-claude-sisyphus) multi-agent orchestration (hooks, agents, skills) |
| `aihero` | [mattpocock/skills](https://github.com/mattpocock/skills) skill pack, copied into `.home/.claude/skills/` at setup time |

Each checkout is locked to one profile with its own `.home/` and `.env`. There's no `--profile`
override flag — that would mix state from two different plugin ecosystems into one home directory.
To use a different profile, clone the repo again into a separate directory.

## GitHub auth

Every profile ships a `/gh-login` skill (seeded into `.home/.claude/skills/` at setup time) that
walks through `gh auth login`'s OAuth device flow — run it once inside a container session, follow
the printed code/URL on your host browser, and `gh`/`git push`/`gh pr create` work from then on.
Credential state lands in `.home/.config/gh/`, bind-mounted like everything else in `.home/`, so it
survives container restarts without re-authenticating each session.

## Auth modes

| Flag | Method | Credential lives in |
|---|---|---|
| `--auth=apikey` (default) | `ANTHROPIC_API_KEY` via a gateway | `.env` (host-side) |
| `--auth=sso` | OAuth via claude.ai | `.home/.claude.json` (container-side) |

Auth mode and profile are orthogonal — any combination is valid. Default mode comes from
`DEFAULT_AUTH` in `.env`, overridable per-invocation with `--auth=sso|apikey`.

**Don't cross the two:** an API key belongs in `.env`, an OAuth token belongs in `.home/`. Keeping
them apart is what keeps `.env`'s host visibility from being a credential leak — see
[CLAUDE.md](CLAUDE.md#credential-placement).

## `.env` schema

`.env` is written interactively by `setup.sh` on first run. `.env.example` documents the schema
with placeholders and is the only one of the two committed to the repo (`.env` is gitignored):

```bash
# Auth
DEFAULT_AUTH=apikey                  # sso or apikey (default: apikey)
ANTHROPIC_API_KEY=                   # required for --auth=apikey, optional otherwise
ANTHROPIC_BASE_URL=                  # gateway URL
ANTHROPIC_MODEL=                     # model ID; set by setup from the gateway's /v1/models

# Mounts
SSH_DIR=                             # SSH key directory; blank = no SSH mount
CLAUDE_WORKDIR=                      # workspace root; blank = use $PWD at runtime

# Container user (set by setup.sh — do not edit manually)
CONTAINER_USER=
CONTAINER_UID=
CONTAINER_GID=
```

## CLI flags

```
claude-sandbox [OPTIONS] [-- CLAUDE_ARGS...]

  --auth=sso|apikey   Override default auth mode from .env
  --model=<id>        Override ANTHROPIC_MODEL for this invocation
  --workdir=<path>    Override working directory for this invocation
  --confirm           Use Claude Code's real permission prompts instead of
                      --dangerously-skip-permissions
  --recover           Wipe and rebuild .env and .home/ for this checkout's
                      already-selected profile (requires confirmation). Does
                      NOT let you change profiles — clone the repo again for
                      that.
  --help              Show this help and exit
  --version           Show claude-sandbox version and exit
  --                  Pass all following args directly to the claude binary
```

Anything after `--` (or any unrecognized flag) is passed straight through to the `claude` binary
inside the container — e.g. `claude-sandbox -- --help` shows Claude Code's own help.

## Recovering

```bash
./claude.sh --recover
```

For when setup broke partway (interrupted image build, corrupted `.home/`, etc.) — wipes `.env` and
`.home/` after a typed confirmation, then re-runs setup for the profile this checkout is already
locked to. It does **not** let you pick a different profile; to use a different profile, clone the
repo again into a separate directory.

## Contributing

See [CLAUDE.md](CLAUDE.md) for repo structure, design decisions, and the development workflow
(shell linting hook, branch/PR conventions). Profile-specific implementation notes (`omc`, `aihero`)
live in each profile's own `CLAUDE.md` under `profiles/<name>/`.
