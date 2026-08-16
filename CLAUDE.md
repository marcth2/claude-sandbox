# claude-sandbox — Developer Guide

Developer-facing companion to [README.md](README.md). Covers repo structure, the reasoning behind
its design decisions, and how to contribute.

## Threat Model

In managed/enterprise environments, Claude Code can be configured with organization-level settings
that run their own logic as part of normal tooling — for example, periodic hooks that execute a
shell command, or shell startup files getting a line appended so a wrapper persists across
sessions. This project doesn't take a position on whether that behavior is expected or desirable;
it treats "org settings can execute code and touch the filesystem" as a generic property of running
Claude Code in a managed environment, and contains it regardless of intent.

**What running inside Docker solves:**
- Any shell execution triggered by org settings is contained inside the container
- Any shell-rc-style writes land in `.home/`, never touching the host's real `~/.bashrc` etc.
- The Docker socket is mounted for `docker`/`gh`/MCP use inside the container; this is an accepted
  risk given the threat model is contained execution, not deliberate container escape

**Structurally enforced, not just observed:** `claude.sh` runs every container with `--read-only`
plus a `tmpfs` mount at `/tmp`. Writes outside `.home/`, the workdir, or `/tmp` fail loudly (a
read-only filesystem error) instead of landing somewhere unmounted and un-inspected. This matters
because auditing every current and future hook by reading its source doesn't scale — the
filesystem itself is the enforcement, not a promise about what hooks are known to do today.

**Accepted, not solved:**
- Telemetry still leaves the container over the network
- Org-managed settings still apply inside the container; a one-time approval dialog appears per
  fresh `.home/`

### Credential placement

Two auth modes, two different trust boundaries:

- **`apikey` mode** — the secret is a gateway API key. It lives host-side, in `.env` (gitignored,
  plain file), and is injected into the container via `-e ANTHROPIC_AUTH_TOKEN=...` at `docker run`
  time.
- **`sso` mode** — the secret is an OAuth token, written by Claude Code's own login flow into
  `.home/.claude.json`. It never touches `.env` or a host shell variable.

Don't cross the two: an API key doesn't belong in `.home/`, and an OAuth token doesn't belong in
`.env`. This isn't enforced by code — it's a convention that keeps `.env`'s host-readability from
becoming a real credential leak, since `.home/` is scoped to whatever already trusts the container
and `.env` is a plain file anyone with checkout access can read.

## Repository Structure

One repo, profiles as subdirectories, no long-lived branches, no separate repos per profile.

```
claude-sandbox/
  claude.sh               ← single entry point: init/dispatch, flag parsing, docker run
  .env.example             ← documents the .env schema, committed
  .gitignore                ← .env, .claude-profile, .home*/
  .githooks/
    pre-commit             ← shellcheck + shfmt on staged *.sh files
  profiles/
    _common.sh             ← shared setup.sh helpers (OS detect, prompts, .env write, build, seed)
    omc/
      Dockerfile           ← node:22-slim + docker/gh CLIs + oh-my-claude-sisyphus npm package
      docker-compose.yml   ← image: claude-code:omc
      setup.sh             ← calls common_* helpers, then `omc setup --quiet`
    aihero/
      Dockerfile           ← same base image as vanilla, no extra npm packages
      docker-compose.yml   ← image: claude-code:base
      setup.sh             ← calls common_* helpers, then git-clones mattpocock/skills into .home/
    vanilla/
      Dockerfile           ← base image, no extras
      docker-compose.yml   ← image: claude-code:base
      setup.sh             ← calls common_* helpers only
```

**Two images, three profiles:** `claude-code:omc` (needs the `oh-my-claude-sisyphus` npm package —
a real system dependency) and `claude-code:base` (used by both `vanilla` and `aihero`, since
aihero's skill pack is just Markdown files copied at setup time, not a system dependency).

**Convention for adding a new profile:** system-level dependencies (packages, binaries, npm
globals) go in that profile's `Dockerfile`; config, skills, and settings go in its `setup.sh`. If
the new profile needs no system dependency beyond the base image, point its `docker-compose.yml`
at `claude-code:base` like `aihero` does instead of building a new image.

## Key Design Decisions

**Profile selection is locked per checkout.** `init()` in `claude.sh` writes the chosen profile to
`.claude-profile` (gitignored) on first run and never offers to change it. A `--profile` override
flag would let one `.home/` accumulate state from two different plugin ecosystems. To try another
profile, clone the repo again — each checkout is independent.

**`.home/` is the entire container `$HOME`,** not just `.claude/`, bind-mounted per checkout. The
container username/uid/gid are captured from the host user at setup time (`CONTAINER_USER/UID/GID`
in `.env`), so file ownership on the mount is correct regardless of who runs setup.

**`--read-only` rootfs + tmpfs `/tmp`** (see [Threat Model](#threat-model) above) — added after
noting that containment via source-reading every known hook doesn't cover hooks or tools not yet
reviewed.

**Docker GID is detected at runtime, not hardcoded**, since the host's `docker` group GID varies
machine to machine:
```bash
case "$(uname -s)" in
    Linux*) DOCKER_GID=$(getent group docker | cut -d: -f3 2>/dev/null || echo "984") ;;
    Darwin*) ;;  # Docker Desktop handles socket permissions via its own proxy
esac
```

**`--dangerously-skip-permissions` is baked into every image's `ENTRYPOINT`,** since the container
itself is the sandbox boundary — auto-approving tool calls inside it doesn't expose the host.
`claude.sh --confirm` overrides the entrypoint to plain `claude` at `docker run` time for anyone who
wants Claude Code's real allow/deny prompts instead.

**Auth injection happens via Docker `-e` flags, never through `settings.json`.** `apikey` mode sets
`ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_BASE_URL`; `sso` mode passes no auth env vars at all and relies on
the OAuth state already in `.home/.claude.json`. See [Credential placement](#credential-placement).

## Platform Support

Linux + native Docker Engine is the only path that's been dogfooded end-to-end across all three
profiles. The macOS and WSL2 code paths in `profiles/_common.sh` and `claude.sh` are real,
implemented logic (OS detection, conditional Docker GID handling, shell-rc-file selection) — not
stubs — but nobody has run them. Docker Desktop's virtualization layer (socket permissions, volume
mount ownership/performance) differs enough from native Docker Engine that "the code path exists"
isn't the same as "it works." Native Windows shells (PowerShell, Git Bash, Cygwin) are rejected
outright by a guard at the top of `claude.sh`; WSL2 is the supported path on Windows.

If you're the first to run this on macOS or WSL2, please file an issue with what broke (or didn't).

## Development Workflow

**Shell linting.** All shell scripts are linted with [shellcheck](https://github.com/koalaman/shellcheck)
and formatted with [shfmt](https://github.com/mvdan/sh) (`-i 4 -ci`). Enable the enforcement hook
once per checkout:
```bash
git config core.hooksPath .githooks
```
`.githooks/pre-commit` lints only staged `*.sh` files and blocks the commit on real findings; it
warns and skips (doesn't block) if shellcheck/shfmt aren't installed locally. Fix a formatting
failure with `shfmt -i 4 -ci -w <file>`.

**Branch and PR flow.** No commits directly to `master`. Each change: a feature/fix branch, commit,
push, open a PR describing what changed and how it was tested, then squash-merge after review.

**Testing expectations.** There's no automated test suite — `claude.sh` and `setup.sh` are
interactive-first scripts. Verify changes by actually running the affected profile(s):
`./claude.sh --reset && ./claude.sh` to walk setup end-to-end, or a scoped `docker run` reproducing
the relevant slice of `claude.sh`'s args to check a specific behavior (e.g. permission mounts,
read-only rootfs). If a change touches `profiles/_common.sh` or `claude.sh`'s docker args, smoke
test all three profiles, not just one — they share that code path.

## Roadmap

- **Phase 1 — Core setup:** done. Three profiles, `.home/` isolation, auth injection, shell
  linting, structural containment (`--read-only`), `--confirm` flag.
- **Phase 2 — Architectural review:** superseded. Rather than a separate review document, design
  decisions have been captured inline here as they were made, with real dogfooding (omc, aihero)
  along the way.
- **Phase 3 — Documentation:** this file and `README.md`.
- **Phase 4 — MCP servers (deferred):** Confluence (via `docker exec` to a host container),
  GitHub (`gh` CLI is already installed; MCP server + `GITHUB_TOKEN` wiring not yet done), Slack,
  Jira/Confluence, AWS, Laravel Boost. Mostly still at the scoping stage — see git history for
  `handoff.md`'s Phase 4 notes if you're picking this up.
