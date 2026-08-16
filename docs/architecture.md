# Architecture

Companion to [CLAUDE.md](../CLAUDE.md). Two diagrams: how a profile maps to a Docker image, and
how a credential gets from `.env` into a running container.

## Profile / image build matrix

Three profiles, two images. `omc` needs an extra npm package baked in, so it gets its own image;
`vanilla` and `aihero` are otherwise-identical Claude Code installs and share one.

```mermaid
flowchart LR
    subgraph Profiles
        vanilla["vanilla\n(no plugins)"]
        aihero["aihero\n(AI Hero skill pack,\ncopied at setup time)"]
        omc["omc\n(oh-my-claude-sisyphus,\nnpm dependency)"]
    end

    subgraph Dockerfiles
        base_df["profiles/vanilla/Dockerfile\nprofiles/aihero/Dockerfile\n(identical)"]
        omc_df["profiles/omc/Dockerfile\n(+ oh-my-claude-sisyphus)"]
    end

    subgraph Images
        base_img["claude-code:base"]
        omc_img["claude-code:omc"]
    end

    vanilla --> base_df
    aihero --> base_df
    omc --> omc_df
    base_df --> base_img
    omc_df --> omc_img
```

`aihero`'s skill pack isn't a system dependency — `setup.sh` clones `mattpocock/skills` and copies
files into `.home/.claude/skills/` after the (shared) image is already built. That's why it shares
`claude-code:base` instead of getting a third image.

## `.home/` mount + auth injection

A checkout is locked to one profile (`.claude-profile`) and has its own `.env` and `.home/`. Every
`claude.sh` invocation reads `.env`, then passes credentials and mounts to `docker run` as flags —
never through `settings.json` inside the container.

```mermaid
flowchart TD
    env[".env\n(host-side file)"] -->|source| claudesh["claude.sh"]

    claudesh -->|"apikey mode:\n-e ANTHROPIC_AUTH_TOKEN\n-e ANTHROPIC_BASE_URL\n-e CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"| container
    claudesh -->|"sso mode:\nno auth env vars —\nOAuth token already in .home/.claude.json"| container

    homedir[".home/\n(host directory,\nfull container $HOME)"] -->|"-v .home:/home/$CONTAINER_USER"| container
    workdir["workspace\n($CLAUDE_WORKDIR or $PWD)"] -->|"-v workdir:workdir"| container
    dockersock["/var/run/docker.sock"] -->|"-v (for docker/gh/MCP use)"| container

    container["container\n(--read-only rootfs,\ntmpfs /tmp,\n--memory 2g --cpus 1.5 --pids-limit 256)"]
```

Two credential paths, never crossed (see [CLAUDE.md](../CLAUDE.md#credential-placement)):

- **`apikey`** — secret lives in `.env` (host-readable by anyone with checkout access), injected
  as `ANTHROPIC_AUTH_TOKEN` at `docker run` time. Never written into `.home/`.
- **`sso`** — secret lives in `.home/.claude.json`, written by Claude Code's own OAuth login the
  first time it runs inside the container. Never written into `.env`.

The `--read-only` rootfs + tmpfs `/tmp` means anything the container writes outside `.home/`, the
workdir, or `/tmp` fails immediately instead of landing somewhere unmounted and un-audited.
