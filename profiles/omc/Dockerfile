FROM node:26-slim

RUN apt-get update && apt-get install -y \
    git curl ca-certificates gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /etc/apt/keyrings/githubcli.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y docker-ce-cli gh \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code oh-my-claude-sisyphus

ARG DOCKER_GID=984
ARG USERNAME=claude
ARG USER_UID=1000
ARG USER_GID=1000
# node:22-slim ships a 'node' user at uid/gid 1000 — rename to match the host user
RUN groupmod -g "${USER_GID}" -n "${USERNAME}" node && \
    usermod -l "${USERNAME}" -u "${USER_UID}" -m -d "/home/${USERNAME}" node && \
    groupadd -g "${DOCKER_GID}" docker && \
    usermod -aG docker "${USERNAME}"

RUN mkdir -p /work/projects && chown "${USERNAME}:${USERNAME}" /work/projects

# Exec-form ENTRYPOINT arrays get neither ARG substitution (not on Docker's
# instruction allowlist) nor runtime shell expansion, but the system-prompt
# seed's path depends on ${USERNAME} (varies per checkout). Bake the resolved
# path into a wrapper script instead, at build time, where ARG substitution
# does apply — exec preserves claude as PID 1 for correct signal handling.
RUN printf '#!/bin/sh\nexec claude --dangerously-skip-permissions --append-system-prompt-file %s "$@"\n' \
    "/home/${USERNAME}/.claude/system-prompt.md" >/usr/local/bin/claude-entrypoint.sh \
    && chmod a+rx /usr/local/bin/claude-entrypoint.sh

USER ${USERNAME}
WORKDIR /work/projects

ENTRYPOINT ["/usr/local/bin/claude-entrypoint.sh"]
