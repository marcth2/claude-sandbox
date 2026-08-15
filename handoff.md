# Claude-Docker Handoff

## Goal

Run Claude Code entirely inside Docker to isolate the host OS from org-managed hooks.
Claude Code is **not** installed on the host OS. The container is the sandbox.

## Threat Model

TELUS org-managed settings (`remote-settings.json`) inject three things into every Claude Code client:

1. **Hook 1** — runs a shell command every 4 min (OAuth token refresh for OTLP telemetry)
2. **Hook 2** — writes `~/.claude/claude-repo-tag.sh` and appends a `source` line to `~/.zshrc`, `~/.bashrc`, `~/.bash_profile` — persists after Claude exits, wraps the `claude` binary
3. **Telemetry** — sends metrics + repo name to `https://apigw-pr.telus.com/common/cioOtelCollector/v1`

**What Docker solves:**
- Hook 1 runs inside the container — arbitrary execution is contained ✓
- Hook 2 writes to `/home/marc/.zshrc` *inside the container* → lands in `.home/.zshrc`, host shell rc files untouched ✓
- Docker socket is acceptable: hooks are doing telemetry, not container escapes ✓

**Accepted / not solved:**
- Telemetry still makes network calls out of the container (accepted by user)
- Org managed settings still apply inside container; approval dialog appears once per fresh `.home/` (expected)

---

## Repository Structure

One repo (`claude-sandbox`), profiles as subdirectories on `main`. No long-lived branches. No separate repos per profile.

```
claude-sandbox/
  claude.sh               ← single entry point, reads .claude-profile, dispatches
  .env.example            ← documents .env schema, committed
  .gitignore              ← .env, .claude-profile, .home*/
  profiles/
    omc/
      Dockerfile          ← npm install -g oh-my-claudecode
      docker-compose.yml  ← image: claude-code:omc
      setup.sh            ← first-run: build image, seed .home/, prompt user
    aihero/
      Dockerfile          ← same base, no extra npm (aihero is config-layer)
      docker-compose.yml  ← image: claude-code:base
      setup.sh            ← build image, git clone mattpocock/skills → .home/.claude/skills/, prompt user
    vanilla/
      Dockerfile          ← no extras
      docker-compose.yml  ← image: claude-code:base
      setup.sh            ← build image, prompt user
```

**Two Docker images only:**
- `claude-code:omc` — has `oh-my-claudecode` npm package (needs OS-level hooks)
- `claude-code:base` — no extras (used by both `vanilla` and `aihero`)

**Why aihero doesn't need its own image:** The AI Hero skill pack (`mattpocock/skills`) is Markdown files in `~/.claude/skills/` — no npm binaries. During `setup.sh`, the host git-clones the repo and copies skill directories directly into `.home/.claude/skills/`. This bypasses the `claude plugins install` marketplace mechanism entirely (which fails headlessly).

**To try a different profile:** clone the repo to a new directory, run `./claude.sh` to trigger `init()`. Each checkout is independent with its own `.home/` and `.env`.

---

## Key Design Decisions

### Profile selection — locked in per checkout

`init()` in `claude.sh` runs when `.claude-profile` doesn't exist:
1. Lists `profiles/*/` directories
2. Prompts user to pick one
3. Writes selected profile name to `.claude-profile` (gitignored)
4. Dispatches to `profiles/<name>/setup.sh`

Once selected, the profile is fixed for that checkout. No `--profile` override flag — that would contaminate `.home/` state. To try another profile: clone again.

**Note:** `.claude-profile` not `.profile` — `.profile` is a reserved Unix shell init filename.

### Auth modes — `--auth=sso|apikey`

| Flag | Auth method | Models | Limit |
|---|---|---|---|
| `--auth=sso` | OAuth via claude.ai (credentials in `.home/`) | Newer (Sonnet 4.x, Opus) | $200/month |
| `--auth=apikey` | `ANTHROPIC_API_KEY` via FuelIX gateway | Older (Sonnet 3.x) | Unlimited |

Auth mode and profile are **orthogonal** — any combination is valid. No automatic fallback between modes. Default auth read from `DEFAULT_AUTH` in `.env`.

### Home directory isolation — `.home/`

Mount `.home/` (per-checkout, gitignored) as `/home/<username>/` (entire home, not just `.claude`). The container username matches the host user (`CONTAINER_USER` in `.env`), so file ownership on mounted volumes is correct on any machine.

This means all hook-written files land in `.home/`:
- `.home/.claude/` → OAuth token, `remote-settings.json`, memories
- `.home/.zshrc` → hook 2 writes here, not to host `~/.zshrc`
- `.home/.claude.json` → legacy auth file

Each profile has its own `.home/` (e.g., `.home-omc/`, `.home-aihero/` if multiple checkouts exist — but conventionally just `.home/` since profiles are separate checkouts).

### Working directory — `CLAUDE_WORKDIR`

`claude.sh` reads `CLAUDE_WORKDIR` from `.env`. Falls back to `$PWD` if unset.

Mount: `-v "$WORKDIR:$WORKDIR"` (same path both sides — host path = container path, no translation needed).

Container starting directory: `$PWD` if inside `$WORKDIR`, otherwise `$WORKDIR` itself.

```bash
WORKDIR="${CLAUDE_WORKDIR:-$(pwd)}"
if [[ "$PWD" == "$WORKDIR"* ]]; then
    CONTAINERDIR="$PWD"
else
    CONTAINERDIR="$WORKDIR"
fi
```

Developer alias stays minimal — workspace path lives in `.env`, not the alias.

### SSH keys

Optional volume mount. `setup.sh` prompts: "SSH key directory [~/.ssh] — press Enter to skip."

Answer stored as `SSH_DIR` in `.env`. `claude.sh` adds `-v "$SSH_DIR:$CONTAINER_HOME/.ssh:ro"` only if `SSH_DIR` is non-empty.

### Docker GID portability

Current Dockerfile hardcodes `groupadd -g 984 docker`. This breaks on machines with a different docker group GID.

Fix in `claude.sh`:
```bash
case "$(uname -s)" in
  Linux*)  DOCKER_GID=$(getent group docker | cut -d: -f3 2>/dev/null || echo "984") ;;
  Darwin*) DOCKER_GID="" ;;  # Docker Desktop handles socket permissions via its own proxy
esac
```

Pass `DOCKER_GID` as a build arg and at runtime via `--group-add`. Skip entirely on macOS.

### `--workdir` flag

`claude.sh` accepts `--workdir=<path>` (or `--workdir <path>`) to override the working directory
for a single invocation. Priority: `--workdir` flag > `CLAUDE_WORKDIR` in `.env` > `$PWD`.

```bash
claude-sandbox --workdir=/work/projects/THWB/Code
```

Useful when `CLAUDE_WORKDIR` is unset and you want to launch into a specific directory without
being in it on the host.

### Argument passthrough to Claude

`claude.sh` parses its own flags (`--auth`, `--workdir`) and passes everything else to the claude binary:

```bash
AUTH="${DEFAULT_AUTH:-sso}"
CLAUDE_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auth=*) AUTH="${1#--auth=}"; shift ;;
        --auth)   AUTH="$2"; shift 2 ;;
        --)       shift; CLAUDE_ARGS+=("$@"); break ;;
        *)        CLAUDE_ARGS+=("$1"); shift ;;
    esac
done
```

So `./claude.sh --auth=sso --continue` works. `--` available for disambiguation if future flag collisions arise.

---

## `.env` Schema

```bash
# Auth
DEFAULT_AUTH=apikey                  # sso or apikey (default: apikey — unlimited via FuelIX)
ANTHROPIC_API_KEY=                   # required for --auth=apikey, optional otherwise
ANTHROPIC_BASE_URL=                  # gateway URL; default is FuelIX (api.fuelix.ai)
ANTHROPIC_MODEL=claude-sonnet-4-6    # model ID for proxy/gateway; set by setup from /v1/models

# Mounts
SSH_DIR=~/.ssh                       # SSH key directory; blank = no SSH mount
CLAUDE_WORKDIR=                      # workspace root; blank = use $PWD at runtime

# Container user (set by setup.sh — do not edit manually)
CONTAINER_USER=                      # host username at setup time (e.g. alice)
CONTAINER_UID=                       # host uid at setup time (e.g. 1000)
CONTAINER_GID=                       # host gid at setup time (e.g. 1000)
```

`setup.sh` writes `.env` interactively. `.env.example` is committed with placeholders.

---

## `setup.sh` Prompt Flow

Runs once per checkout via `init()`. Per-profile `setup.sh` in `profiles/<name>/`:

```
1. Detect OS → linux | macos | wsl (affects GID logic and printed notes)
2. Default auth mode? [sso/apikey] (default: sso)
3. ANTHROPIC_API_KEY — press Enter to skip (required only if apikey)
4. ANTHROPIC_BASE_URL — press Enter for api.anthropic.com
5. SSH key directory [~/.ssh] — press Enter to skip (no git push from container)
6. Default workspace directory [$PWD] — press Enter for current directory
7. Write .env
8. Build Docker image (docker compose build with correct GID arg)
9. [aihero only] Run plugin install one-off container to seed .home/
10. Print alias to add to ~/.bash_aliases
11. Print first-run notes:
    - SSO: "Look for a URL in the terminal — open it in your host browser"
    - All: "Approve the TELUS managed settings dialog — happens once per profile"
```

**Suggested alias (user adds to `~/.bash_aliases`):**
```bash
alias claude='/path/to/claude-sandbox/claude.sh'
# With explicit auth default:
alias claude='/path/to/claude-sandbox/claude.sh --auth=sso'
```

All workspace/SSH config lives in `.env` — alias stays minimal.

---

## macOS / WSL Notes

**macOS (Docker Desktop):**
- No `getent` — skip docker group GID logic entirely
- Docker Desktop handles socket permissions via its own proxy — no `group_add` needed
- SSH keys at `~/.ssh` work normally
- File paths differ (`/Users/username/...`) — handled by `CLAUDE_WORKDIR` in `.env`

**Windows (Docker Desktop + WSL2):**
- Run `claude.sh` from inside the WSL2 terminal, not PowerShell/CMD
- SSH keys should be the WSL `~/.ssh`, not the Windows `%USERPROFILE%\.ssh`
- Otherwise behaves identically to Linux
- `setup.sh` prints a warning if it detects a non-WSL Windows environment

---

## `claude.sh` Structure (root entry point)

```bash
#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_FILE="$REPO_DIR/.claude-profile"

# First run: init
if [[ ! -f "$PROFILE_FILE" ]]; then
    init   # list profiles, prompt, write .claude-profile, dispatch to setup.sh
    exit 0
fi

PROFILE=$(cat "$PROFILE_FILE")
PROFILE_DIR="$REPO_DIR/profiles/$PROFILE"
ENV_FILE="$REPO_DIR/.env"

# Load .env
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# Parse claude.sh flags, pass rest to claude
AUTH="${DEFAULT_AUTH:-sso}"
CLAUDE_ARGS=()
# ... (arg parsing loop as above)

# Resolve workdir
WORKDIR="${CLAUDE_WORKDIR:-$(pwd)}"
# ... (CONTAINERDIR logic)

# Build docker args
DOCKER_ARGS=(run --rm -it -w "$CONTAINERDIR")
DOCKER_ARGS+=(-v "$WORKDIR:$WORKDIR")
DOCKER_ARGS+=(-v "$REPO_DIR/.home:$CONTAINER_HOME")
[[ -n "${SSH_DIR:-}" ]] && DOCKER_ARGS+=(-v "$SSH_DIR:$CONTAINER_HOME/.ssh:ro")

if [[ "$AUTH" == "apikey" ]]; then
    [[ -z "${ANTHROPIC_API_KEY:-}" ]] && { echo "Error: ANTHROPIC_API_KEY not set in .env"; exit 1; }
    DOCKER_ARGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
    [[ -n "${ANTHROPIC_BASE_URL:-}" ]] && DOCKER_ARGS+=(-e "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL")
fi

exec docker compose -f "$PROFILE_DIR/docker-compose.yml" "${DOCKER_ARGS[@]}" claude "${CLAUDE_ARGS[@]}"
```

---

## Implementation Checklist

### Phase 1 — Core setup (implement + manually test)

#### Carry forward from previous session
- [x] Update `.gitignore` to exclude `.env`, `.claude-profile`, `.home*/`
- [ ] Delete `/work/projects/Claude-Docker/` (old repo — low priority, not blocking)

#### New work — COMPLETE
- [x] Create `profiles/omc/`, `profiles/aihero/`, `profiles/vanilla/` with Dockerfile, docker-compose.yml, setup.sh each
- [x] Move existing `Dockerfile` + `docker-compose.yml` into `profiles/omc/`; update image name to `claude-code:omc`
- [x] Fix `docker-compose.yml` build context: `context: ../..`, `dockerfile: profiles/omc/Dockerfile`
- [x] Rewrite root `claude.sh` with `init()`, arg parsing, `.claude-profile` dispatch
- [x] Write `profiles/*/setup.sh` with full prompt flow (OS detect, auth, API key, SSH, workdir, build, alias print)
- [x] Fix Docker GID: build arg + runtime `--group-add` (via `docker run`, not `docker compose run` — compose doesn't support `--group-add`)
- [x] Write `.env.example` with all keys documented
- [x] Seed `.home/.claude/settings.json` from `setup.sh` (see Seeded Settings below)
- [x] Seed `.home/.claude/CLAUDE.md` from `setup.sh` for omc profile only (copy from `~/.claude/CLAUDE.md`)
- [x] Add `--reset`, `--help`, `--version` flags to `claude.sh`
- [x] Add `VERSION` file; `--version` reads from it

#### Phase 1 testing — IN PROGRESS
- [x] vanilla profile setup flow works end-to-end (tested fresh reset + re-setup)
- [x] Test apikey/FuelIX auth flow (`--auth=apikey`) — works; `claude-sonnet-5` confirmed available on TELUS FuelIX
- [x] Test SSO auth flow (`--auth=sso`, `BROWSER=echo`) — works; URL printed to terminal, paste into host browser; Claude Enterprise with Opus 5 available
- [x] Test omc profile setup end-to-end (CLAUDE.md copy, .omc-config.json seed, ANTHROPIC_MODEL injected, omc skills confirmed working)
- [x] `--model=non-exist` flag passthrough confirmed — FuelIX 403 surfaced cleanly in Claude Code UI
- [x] Test aihero profile setup end-to-end — git clone install works; 35 skills installed, container launches cleanly (tested 2026-08-15)
- [x] Dogfood aihero profile — `/wayfinder` skill worked; discovered `gh` CLI missing; `gh` added to all 3 Dockerfiles (2026-08-15)

#### Setup flow fixes applied during testing
- `docker compose run` does not support `--group-add` — switched `claude.sh` to `docker run` directly; compose files retained for build only
- API key prompt now silent (`read -rs`) — was visible in terminal
- ANTHROPIC_BASE_URL prompt replaced with numbered menu; api.anthropic.com is default [1], FuelIX available as option 2
- API key prompt skipped when BASE_URL is blank (no gateway = no key needed)
- SSH directory defaults to `~/.ssh`; type `skip` to omit mount; `read -e` added for tab completion on SSH and workspace prompts
- Workspace directory default removed — was showing caller's `$PWD` which is too narrow; now blank (falls back to `$PWD` at runtime)
- Alias auto-written to shell config file (`~/.bash_aliases` on Linux/WSL, `~/.zshrc` on macOS+zsh, `~/.bash_profile` on macOS+bash) — default name `claude-sandbox`; searched by repo path so rename works on re-setup; source reminder printed in closing banner
- Profile list ordered (vanilla → omc → aihero) with one-line descriptions; vanilla is default [1]
- Model selection defaults to recommended (`claude-sonnet-5`) — index pre-selected, no blank entry allowed
- Closing banner moved to `init()` — shows configuration summary with masked API key; `Run: source` + `Run: <alias>` at the end
- Unsupported OS guard added (MINGW/MSYS/CYGWIN) — fails fast with WSL2 redirect message
- `exec docker run` bug fixed — `DOCKER_ARGS` already starts with `run`; was launching image named `run`; fixed to `exec docker`
- `--workdir=<path>` flag added to `claude.sh` for per-invocation working directory override (priority: flag > CLAUDE_WORKDIR in .env > $PWD)
- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` added to apikey Docker `-e` inject — FuelIX needs it as a real env var, not just in settings.json
- Image existence check added to `claude.sh` — gives clear error + reset instructions if setup was interrupted before image build
- Org managed settings dialog note moved inside SSO block — dialog only appears on SSO, not apikey
- `.omc-config.json` pre-seeded in omc `setup.sh` — prevents OMC from launching interactive setup wizard (which requests opus) on first launch; `docker run --entrypoint node` used to get omc version (container ENTRYPOINT intercepts bare `node` otherwise)
- `ANTHROPIC_MODEL` added to `.env` — set during setup via curl `/v1/models` enumeration; `claude-sonnet-5` is recommended default on FuelIX; injected into container via `-e`
- `--model=<id>` flag added to `claude.sh` — per-invocation override of `ANTHROPIC_MODEL` (priority: flag > .env > unset)
- Reset message now shows actual script path instead of hardcoded `claude-sandbox`
- TELUS/org-specific references removed from scripts — BASE_URL menu now defaults to api.anthropic.com [1] with FueliX as option 2; "org managed settings" used in messaging
- Phases restructured: Phase 2 = architectural review (OMC + aihero), Phase 3 = README + CLAUDE.md, Phase 4 = MCP Servers
- Container username/UID portability fix — `marc` and UID 1000 were hardcoded throughout; now all 3 Dockerfiles accept `USERNAME`, `USER_UID`, `USER_GID` build args; `setup.sh` captures `$(id -un/u/g)` at setup time, writes to `.env` as `CONTAINER_USER/UID/GID`, passes as `--build-arg`; `claude.sh` derives `CONTAINER_HOME` from `CONTAINER_USER` after sourcing `.env`; aihero plugin install path also fixed
- `claude-docker` → `claude-sandbox` renamed in all 4 remaining instances in `claude.sh` (usage header, help text, both `--version` handlers)
- FuelIX (`api.fuelix.ai`) promoted to default [1] in BASE_URL menu across all 3 `setup.sh` files; api.anthropic.com moved to option 2
- Model list heading changed from `"Available Claude models:"` to `"Available models on $BASE_URL:"` — makes clear which gateway the list comes from
- SSO path now prints `"SSO: select your model inside Claude Code with /model"` instead of silently skipping model selection
- aihero plugin install completely replaced — `claude plugins install mattpocock-skills` fails headlessly (marketplace auth not available in container); new approach: host git-clones `mattpocock/skills` at setup time, copies skill dirs from `skills/` (excluding `deprecated/`) into `.home/.claude/skills/`; no container involvement in install; 35 skills confirmed installed on test
- Shell injection via `alias_name` fixed — strip non-`[a-zA-Z0-9_-]` chars before writing to rc file
- `local -A` (bash 4+) replaced with `_profile_desc()` case function — fixes macOS bash 3.2 incompatibility
- Profile picker now validates numeric input before array indexing — clean error message instead of raw arithmetic failure
- `mktemp` dir in aihero setup now cleaned via `trap EXIT` — was leaking on `git clone` failure
- `gh` CLI added to all 3 Dockerfiles — GitHub CLI apt keyring, same pattern as Docker CE; must be in Dockerfile because runtime `apt-get` fails inside hardened containers (`--cap-drop ALL` + `no-new-privileges` block privilege transitions even for root via `docker exec`)
- `gh auth login --web` appears to freeze in container — `BROWSER=echo` prevents auto-launch; `gh` polls device auth endpoint silently; user must manually open the printed device URL; auth state persists in `.home/.config/gh/` once complete; full auth wiring deferred to Phase 4 alongside `GITHUB_TOKEN`

#### Code review findings (from in-container review, 2026-08-15)

**Fixed (commit `e9ede0b`):**
- ~~Shell injection via `alias_name`~~ — sanitize to `[a-zA-Z0-9_-]` before writing rc file
- ~~`local -A` breaks macOS~~ — replaced with `_profile_desc()` case function (bash 3.2 compatible)
- ~~Profile picker no input validation~~ — numeric guard before array indexing
- ~~`mktemp` leaks on `git clone` failure~~ — `trap 'rm -rf "$SKILLS_TMP"' EXIT` added

**Fixed (2026-08-15, session 3):**
- ~~`profiles/_common.sh` refactor~~ — OS detection, auth/model prompts, `.env` write, and build extracted to `profiles/_common.sh`; each setup.sh now ~30–80 lines of profile-specific code only
- ~~Docker socket + skip-permissions design review~~ — accepted risk (threat model is org hooks, not malicious Claude); `--dangerously-skip-permissions` kept in ENTRYPOINT; dead `"permissions"` block removed from seeded settings.json
- ~~`gh` CLI missing from Dockerfiles~~ — added to all 3 via GitHub CLI apt repo (discovered during aihero dogfood session)

**Pending for next session:**
- **Rebuild images** — Dockerfiles changed (added `gh`); existing cached images don't have it. Run `./claude.sh --reset` and redo setup, or `docker compose -f profiles/<name>/docker-compose.yml build` directly.

---

## Seeded Settings (written by `setup.sh` into `.home/.claude/settings.json`)

Auth tokens must **never** appear here — injected by Docker `-e` only.

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "permissions": {
    "allow": []
  },
  "skipDangerousModePermissionPrompt": true,
  "skipWorkflowUsageWarning": true,
  "alwaysThinkingEnabled": true,
  "spinnerTipsEnabled": true,
  "theme": "dark",
  "enabledPlugins": {
    "oh-my-claudecode@omc": true
  },
  "extraKnownMarketplaces": {
    "omc": {
      "source": {
        "source": "git",
        "url": "https://github.com/Yeachan-Heo/oh-my-claudecode.git"
      }
    }
  },
  "statusLine": {
    "type": "command",
    "command": "node ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud/omc-hud.mjs"
  }
}
```

`enabledPlugins` and `extraKnownMarketplaces` only in `omc` profile's seeded settings.json.
`statusLine` only in `omc` profile.

---

## Auth injection (`claude.sh`)

```bash
if [[ "$AUTH" == "apikey" ]]; then
    [[ -z "${ANTHROPIC_API_KEY:-}" ]] && { echo "Error: ANTHROPIC_API_KEY not set"; exit 1; }
    DOCKER_ARGS+=(-e "ANTHROPIC_AUTH_TOKEN=$ANTHROPIC_API_KEY")
    [[ -n "${ANTHROPIC_BASE_URL:-}" ]] && DOCKER_ARGS+=(-e "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL")
    DOCKER_ARGS+=(-e "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1")
fi
# SSO: no auth env vars passed — Claude uses OAuth from .home/.claude.json

# Model (both auth modes — --model flag overrides .env)
EFFECTIVE_MODEL="${MODEL_OVERRIDE:-${ANTHROPIC_MODEL:-}}"
[[ -n "$EFFECTIVE_MODEL" ]] && DOCKER_ARGS+=(-e "ANTHROPIC_MODEL=$EFFECTIVE_MODEL")
```

`ANTHROPIC_MODEL` is set during setup by enumerating `/v1/models` from the gateway and stored in `.env`.
In the container, settings.json never contains auth tokens — Docker env vars only.

### FuelIX model findings

FuelIX `/v1/models` does **not** expose `claude-opus-5` or any opus model. The Claude models available
on the TELUS FuelIX account as of 2026-08-15:

- `claude-sonnet-5` ← **recommended default**
- `claude-sonnet-4-6`
- `claude-sonnet-5`, `claude-sonnet-4-5`, `claude-sonnet-4`, `claude-3-7-sonnet`
- `claude-haiku-4-5`, `claude-haiku-4`, `claude-3-5-haiku`

The "Opus 5" shown in Claude Code's welcome screen when no model is pinned is a UI default label —
any explicit request for `claude-opus-5` gets a 403. Pinning `ANTHROPIC_MODEL=claude-sonnet-4-6`
prevents OMC subagents (which request opus by model name) from hitting this 403.

OMC's MODEL ROUTING OVERRIDE hook detects FuelIX via `ANTHROPIC_BASE_URL` not containing `anthropic.com`
and injects a system reminder telling Claude not to pass explicit model params to subagents — subagents
then inherit the session model (`claude-sonnet-4-6`) instead of requesting opus.

**Auth modes tested:**
- `--auth=apikey` (FuelIX): Sonnet 5 available, Opus 5 not licensed on TELUS FuelIX account → "API Usage Billing"
- `--auth=sso` (claude.ai): Claude Enterprise, Opus 5 + Sonnet 5 available → "Claude Enterprise"

---

## Telemetry Decision

**Option A chosen (soft):** Do not pass `OTEL_*` env vars (`OTEL_CLIENT_ID`, `OTEL_CLIENT_SECRET`,
`OTEL_TOKEN_ENDPOINT`, `OTEL_SCOPE`) to the container. The `get-otel-token.sh` hook (injected by
remote-settings) will run, find no credentials, and exit silently with `{}`. Telemetry calls may
still attempt to reach `https://apigw-pr.telus.com/...` but without a valid auth token.

If this proves noisy, escalate to Option B: add `--add-host apigw-pr.telus.com:0.0.0.0` to
`claude.sh`'s DOCKER_ARGS to hard-block the hostname inside the container.

---

## Phase 2 — Architectural Review (deferred)

Run an architectural review of the project using OMC (omc profile) and aihero (aihero profile) — using the tool itself to review its own design. Goals:

- Validate the profile/image split, `.home/` isolation, and auth injection approach
- Identify any security, usability, or portability gaps
- Produce a list of recommendations to carry into Phase 3/4

---

## Phase 3 — Documentation (deferred)

Author two files:

- **README.md** — user-facing: what the project does, threat model summary, quick-start per profile, `.env` schema, auth modes, `--workdir` / `--model` flags, reset instructions, macOS/WSL notes
- **CLAUDE.md** — developer-facing: repo structure, design decisions (profile lock, image split, `.home/` isolation, Docker GID logic), phase roadmap, contribution guidance

---

## Phase 4 — MCP Servers (deferred)

Design is partially resolved. Implement after Phase 1 is stable.

### Confluence (already Docker-based)
- Current host config (`mcp.json.TH1.OLD`): `docker exec -i confluence-mcp-server python confluence-server.py`
- Approach: identical inside the container — Docker socket is mounted, so `docker exec` to a running host container works
- Requires `confluence-mcp-server` container to be running on the host before launching claude-sandbox
- No Dockerfile changes needed

### GitHub
- `gh` CLI is installed in all 3 Dockerfiles (done 2026-08-15)
- Auth wiring: add `GITHUB_TOKEN` to `.env` (classic PAT, SSO-authorized for TELUS org); setup.sh runs
  `gh auth login --with-token <<< "$GITHUB_TOKEN"` so CLI is configured automatically; token also
  injected via `-e GITHUB_TOKEN` for the MCP server — one token wires both
- SSO note: TELUS Health uses SAML SSO on `github.com` — after creating the PAT, go to
  GitHub org settings → Authorize the token for the org
- MCP server (`@modelcontextprotocol/server-github`): optional structured Claude tool access
  (read/create PRs, issues); uses `GITHUB_TOKEN` env var
- `gh auth` state persists in `.home/.config/gh/` — survives container restarts

### Slack
- Server: `@modelcontextprotocol/server-slack` (npm, stdio)
- Install: `npm install -g @modelcontextprotocol/server-slack` in Dockerfile
- Auth: `SLACK_BOT_TOKEN` in `.env`, injected via `-e`

### Jira / Confluence (Atlassian)
- Separate from the Docker-exec Confluence MCP above
- TBD: evaluate available npm/Python MCP servers for Jira
- May require Atlassian API token in `.env`

### AWS
- Credentials: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` in `.env`
  or mount `~/.aws/` into container
- OpenVPN: required for RDS access — evaluate whether VPN runs on host (container inherits
  host network routes if `--network host`) or inside container (complex, not recommended)
- RDS MySQL: connection strings per environment in `.env` or a secrets manager
- MCP server: `awslabs/mcp` collection — TBD which servers are needed
- Recommended: run VPN on host, container inherits routes via bridge networking

### Laravel Boost
- TBD: determine package name, install method (npm/pip/custom), auth requirements

---

## Notes
- `apt-get` fails at container runtime even as root via `docker exec` — `--cap-drop ALL` + `no-new-privileges` block the privilege transitions apt needs. All packages must be installed in the Dockerfile at build time. This is expected; use `docker build` to add packages, not live installs.
- `--dangerously-skip-permissions` in ENTRYPOINT is intentional: container is the sandbox
- Docker socket is mounted; acceptable given threat model (hooks do telemetry, not container escapes)
- Container user matches host user (`CONTAINER_USER/UID/GID` in `.env`) — file ownership on mounted volumes is correct regardless of who runs setup
- First run of a new profile shows the org managed settings approval dialog — approve once;
  consent saved to `.home/.claude/remote-settings-consent.json`, not shown again
- `ANTHROPIC_AUTH_TOKEN` (FuelIX key) was previously hardcoded in host `settings.json` env block —
  this is the pattern to avoid in the container; all auth comes from `.env` → Docker `-e`
